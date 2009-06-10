module Network.Whiteout
    (
-- *Torrents
    Torrent(..),
    PieceNum,
    loadTorrentFromFile,
    loadTorrentFromURL,
    LoadTorrentFromURLError(..),
    loadTorrent,
-- *Whiteout state
    Session(),
    TorrentSt(),
    Activity(..),
    torrent,
    path,
    initialize,
    close,
    getActiveTorrents,
    isPieceComplete,
    getActivity,
-- *Operations on torrents
    addTorrent,
    beginVerifyingTorrent,
    addPeer
    ) where

import Control.Applicative
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (replicateM)
import Data.Array.IArray ((!), bounds, listArray)
import Data.Array.MArray (newArray, readArray, writeArray)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as L
import Data.Digest.Pure.SHA (bytestringDigest, sha1)
import qualified Data.Map as M
import Data.Maybe (fromMaybe)
import Network.URI (parseURI)
import Network.HTTP
    (Response(..), RequestMethod(..), mkRequest, simpleHTTP)
import System.Directory
    (Permissions(..), doesDirectoryExist, doesFileExist, getPermissions)
import System.FilePath ((</>), joinPath)
import System.IO
import System.Random

import Internal.BEncode
import Internal.Peer (addPeer)
import Internal.Pieces
import Internal.Types


-- | Load a torrent from a file. Returns 'Nothing' if the file doesn't contain a
-- valid torrent. Throws an exception if the file can't be opened.
loadTorrentFromFile :: FilePath -> IO (Maybe Torrent)
loadTorrentFromFile = fmap loadTorrent . L.readFile

-- | Load a torrent from a URL.
loadTorrentFromURL ::
    String ->
    IO (Either LoadTorrentFromURLError Torrent)
loadTorrentFromURL u =
    case parseURI u of
        Just uri' -> do
            let req = mkRequest GET uri'
            res <- simpleHTTP req
            case res of
                Left _  -> return $ Left DownloadFailed
                Right r -> return $ case loadTorrent $ rspBody r of
                    Just t  -> Right t
                    Nothing -> Left NotATorrent
        Nothing   -> return $ Left URLInvalid

-- | Things that could go wrong downloading and loading a torrent.
data LoadTorrentFromURLError =
    -- | Download failed.
      DownloadFailed
    -- | URL was invalid.
    | URLInvalid
    -- | Download succeeded, but what we got was not a torrent.
    | NotATorrent
    deriving (Show, Eq)

-- | Load a torrent from a 'L.ByteString'. Returns 'Nothing' if the parameter
-- is not a valid torrent.
loadTorrent :: L.ByteString -> Maybe Torrent
loadTorrent bs = bRead bs >>= toTorrent

toTorrent :: BEncode -> Maybe Torrent
toTorrent benc = do
    dict <- getDict benc
    announce <- M.lookup "announce" dict >>= getString
    info <- M.lookup "info" dict >>= getDict
    let
        infohash = B.concat $ L.toChunks $ bytestringDigest $ sha1 $ bPack $
            BDict info
    pieceLen <- M.lookup "piece length" info >>= getInt
    pieceHashes <- M.lookup "pieces" info >>= getString
    pieceHashes' <- extractHashes pieceHashes
    name <- M.lookup "name" info >>= getString
    files <- getFiles info
    Just Torrent
        {announce = announce,
         name = name,
         pieceLen = fromIntegral pieceLen,
         pieceHashes =
            listArray
                (0,(fromIntegral $ B.length pieceHashes `div` 20) - 1)
                pieceHashes',
         tInfohash = infohash,
         files = files
        } >>= checkLength
    where
        --The get* could probably all be replaced with something using generics.
        getInt i = case i of
            BInt i' -> Just i'
            _       -> Nothing
        getString s = case s of
            BString s' -> Just s'
            _          -> Nothing
        getList l = case l of
            BList l' -> Just l'
            _        -> Nothing
        getDict d = case d of
            BDict d' -> Just d'
            _        -> Nothing
        extractHashes hs = if (B.length hs `mod` 20) == 0
            then Just $ groupHashes hs
            else Nothing
        groupHashes hs = if B.null hs
            then []
            else let (hash, rest) = B.splitAt 20 hs in hash : groupHashes rest
        getFiles i = let
            length = M.lookup "length" i >>= getInt
            files  = M.lookup "files" i >>= getList
            in case (length, files) of
                (Just i  , Nothing) -> Just $ Left i
                (Nothing , Just fs) -> fmap Right $ mapM getFile fs
                (Just _  , Just _ ) -> Nothing
                (Nothing , Nothing) -> Nothing
        getFile :: BEncode -> Maybe (Integer, FilePath)
        getFile d = do
            d' <- getDict d
            length <- M.lookup "length" d' >>= getInt
            path <- M.lookup "path" d' >>= getList >>= mapM getString
            let path' = joinPath $ map BC.unpack path
            Just (length,path')
        checkLength t = let
            len = either id (sum . map fst) $ files t
            numPieces = snd (bounds $ pieceHashes t) + 1
            numPieces' = 
                ceiling
                    ((fromIntegral len :: Double) / (fromIntegral $ pieceLen t))
            in if numPieces == numPieces'
                then Just t
                else Nothing

-- This should eventually take more arguments. At least a port to listen on.
initialize :: Maybe (B.ByteString)
    -- ^ Your client name and version. Must be exactly two characters, followed
    -- by four numbers. E.g. Azureus uses AZ2060.
    --
    -- See <http://wiki.theory.org/BitTorrentSpecification#peer_id> for a
    -- directory. If you pass 'Nothing', we'll use WO and the whiteout version.
    -> IO Session
initialize name = do
    peerId <- genPeerId $ fromMaybe "WO0001" name
    atomically $ do
        torrents <- newTVar M.empty
        return Session { torrents = torrents, sPeerId = peerId }

genPeerId :: B.ByteString -> IO B.ByteString
genPeerId nameandver = do
    randompart <- BC.pack <$> (replicateM 12 $ randomRIO ('0','9'))
    return $ B.concat ["-", nameandver, "-", randompart]

-- | Clean up after ourselves, closing file handles, ending connections, etc.
-- Run this before exiting.
close :: Session -> IO ()
close _ = return ()

-- | Get the currently active torrents, keyed by infohash. A torrent is active
-- as long as it has been 'addTorrent'ed; one can be simultaneous active and
-- stopped - ready to go but not actually doing anything yet.
getActiveTorrents :: Session -> STM (M.Map B.ByteString TorrentSt)
getActiveTorrents = readTVar . torrents

isPieceComplete :: TorrentSt -> PieceNum -> STM Bool
isPieceComplete = readArray . completion

getActivity :: TorrentSt -> STM Activity
getActivity = readTVar . activity

-- | Add a torrent to a running session for seeding/checking. Since we only
-- support seeding at present, this requires the files be in place and of the
-- correct size. Returns 'True' on success.
addTorrent :: Session -> Torrent -> FilePath -> IO Bool
addTorrent sess tor path = case files tor of
    Left len -> do
        ok <- checkFile (len,path)
        if ok
            then atomically addTorrent' >> return True
            else return False
    Right fs -> do
        e <- doesDirectoryExist path
        if e
            then do
                p <- getPermissions path
                if readable p
                    then do
                        ok <- fmap and $ mapM (checkFile . addprefix) fs
                        if ok
                            then atomically addTorrent' >> return True
                            else return False
                    else return False
            else return False
    where
        addprefix (l,p) = (l, path </> p)
        checkFile :: (Integer, FilePath) -> IO Bool
        checkFile (size, path) = do
            e <- doesFileExist path
            if e
                then do
                    p <- getPermissions path
                    if readable p
                        then withBinaryFile path ReadMode $ \h -> do
                            size' <- hFileSize h
                            if size == size'
                                then return True
                                else return False
                        else return False
                else return False
        addTorrent' :: STM ()
        addTorrent' = do
            torsts <- readTVar $ torrents sess
            completion <- newArray (bounds $ pieceHashes tor) False
            activity <- newTVar Stopped
            let
                torst = TorrentSt {
                    torrent = tor,
                    path = path,
                    completion = completion,
                    activity = activity
                    }
                torsts' = M.insert (tInfohash tor) torst torsts
            writeTVar (torrents sess) torsts'

-- | Launch a thread to asynchronously verify the hashes of a torrent.
--
-- If the torrent is not 'Stopped', this will return false and abort. Otherwise,
-- it will set 'Activity' to 'Verifying', then back to 'Stopped' when the
-- process is finished.
beginVerifyingTorrent :: TorrentSt -> IO Bool
beginVerifyingTorrent torst = do
    a <- atomically $ getActivity torst
    case a of
        Stopped -> do
            atomically $ writeTVar (activity torst) Verifying
            forkIO (verify 0)
            return True
        _ -> return False
    where
        verify :: PieceNum -> IO ()
        verify piecenum = do
            piece <- getPiece torst piecenum
            case piece of
                Nothing -> do
                    atomically $ writeTVar (activity torst) Stopped
                    error "Couldn't load a piece for verifying!"
                    -- TODO we need a real error logging mechanism.
                Just piece' -> do
                    let
                        expected = (pieceHashes $ torrent torst) ! piecenum
                        actual = B.concat $ L.toChunks $ bytestringDigest $
                            sha1 $ L.fromChunks [piece']
                    if actual == expected
                        then atomically $
                            writeArray (completion torst) piecenum True
                        else atomically $
                            writeArray (completion torst) piecenum False
                    if piecenum == (snd $ bounds $ pieceHashes $ torrent torst)
                        then atomically $ writeTVar (activity torst) Stopped
                        else verify (piecenum+1)
