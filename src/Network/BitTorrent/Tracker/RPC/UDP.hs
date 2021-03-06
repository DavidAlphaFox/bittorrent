-- |
--   Copyright   :  (c) Sam Truzjan 2013-2014
--   License     :  BSD3
--   Maintainer  :  pxqr.sta@gmail.com
--   Stability   :  provisional
--   Portability :  portable
--
--   This module implement UDP tracker protocol.
--
--   For protocol details and uri scheme see:
--   <http://www.bittorrent.org/beps/bep_0015.html>,
--   <https://www.iana.org/assignments/uri-schemes/prov/udp>
--
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable         #-}
module Network.BitTorrent.Tracker.RPC.UDP
       ( -- * Manager
         Options (..)
       , Manager
       , newManager
       , closeManager
       , withManager

         -- * RPC
       , RpcException (..)
       , announce
       , scrape
       ) where

import Control.Applicative
import Control.Concurrent
import Control.Exception
import Control.Monad
import Data.Default
import Data.IORef
import Data.List as L
import Data.Map  as M
import Data.Maybe
import Data.Serialize
import Data.Text as T
import Data.Time
import Data.Time.Clock.POSIX
import Data.Traversable
import Data.Typeable
import Text.Read (readMaybe)
import Network.Socket hiding (Connected, connect, listen)
import Network.Socket.ByteString as BS
import Network.URI
import System.Timeout

import Network.BitTorrent.Tracker.Message

{-----------------------------------------------------------------------
--  Options
-----------------------------------------------------------------------}

-- | 'System.Timeout.timeout' specific.
sec :: Int
sec = 1000000

-- | See <http://www.bittorrent.org/beps/bep_0015.html#time-outs>
defMinTimeout :: Int
defMinTimeout = 15

-- | See <http://www.bittorrent.org/beps/bep_0015.html#time-outs>
defMaxTimeout :: Int
defMaxTimeout = 15 * 2 ^ (8 :: Int)

-- | See: <http://www.bittorrent.org/beps/bep_0015.html#time-outs>
defMultiplier :: Int
defMultiplier = 2

-- TODO why 98?
defMaxPacketSize :: Int
defMaxPacketSize = 98

-- | Manager configuration.
data Options = Options
  { -- | Max size of a /response/ packet.
    --
    --   'optMaxPacketSize' /must/ be a positive value.
    --
    optMaxPacketSize :: {-# UNPACK #-} !Int

    -- | Starting timeout interval in seconds. If a response is not
    -- received after 'optMinTimeout' then 'Manager' repeat RPC with
    -- timeout interval multiplied by 'optMultiplier' and so on until
    -- timeout interval reach 'optMaxTimeout'.
    --
    --   'optMinTimeout' /must/ be a positive value.
    --
  , optMinTimeout    :: {-# UNPACK #-} !Int

    -- | Final timeout interval in seconds. After 'optMaxTimeout'
    -- reached and tracker still not responding both 'announce' and
    -- 'scrape' functions will throw 'TimeoutExpired' exception.
    --
    --   'optMaxTimeout' /must/ be greater than 'optMinTimeout'.
    --
  , optMaxTimeout    :: {-# UNPACK #-} !Int

    -- | 'optMultiplier' /must/ be a positive value.
  , optMultiplier    :: {-# UNPACK #-} !Int
  } deriving (Show, Eq)

-- | Options suitable for bittorrent client.
instance Default Options where
  def = Options
    { optMaxPacketSize = defMaxPacketSize
    , optMinTimeout    = defMinTimeout
    , optMaxTimeout    = defMaxTimeout
    , optMultiplier    = defMultiplier
    }

checkOptions :: Options -> IO ()
checkOptions Options {..} = do
  unless (optMaxPacketSize > 0) $ do
    throwIO $ userError "optMaxPacketSize must be positive"

  unless (optMinTimeout > 0) $ do
    throwIO $ userError "optMinTimeout must be positive"

  unless (optMaxTimeout > 0) $ do
    throwIO $ userError "optMaxTimeout must be positive"

  unless (optMultiplier > 0) $ do
    throwIO $ userError "optMultiplier must be positive"

  unless (optMaxTimeout > optMinTimeout) $ do
    throwIO $ userError "optMaxTimeout must be greater than optMinTimeout"


{-----------------------------------------------------------------------
--  Manager state
-----------------------------------------------------------------------}

type ConnectionCache     = Map SockAddr Connection

type PendingResponse     = MVar (Either RpcException Response)
type PendingTransactions = Map TransactionId PendingResponse
type PendingQueries      = Map SockAddr      PendingTransactions

-- | UDP tracker manager.
data Manager = Manager
  { options         :: !Options
  , sock            :: !Socket
--  , dnsCache        :: !(IORef (Map URI SockAddr))
  , connectionCache :: !(IORef ConnectionCache)
  , pendingResps    :: !(MVar  PendingQueries)
  , listenerThread  :: !(MVar ThreadId)
  }
-- 初始化UDP的Tracker Manager
initManager :: Options -> IO Manager
initManager opts = Manager opts
  <$> socket AF_INET Datagram defaultProtocol
  <*> newIORef M.empty
  <*> newMVar  M.empty
  <*> newEmptyMVar

unblockAll :: PendingQueries -> IO ()
unblockAll m = traverse (traverse unblockCall) m >> return ()
  where
    unblockCall ares = putMVar ares (Left ManagerClosed)

resetState :: Manager -> IO ()
resetState Manager {..} = do
    writeIORef          connectionCache err
    m    <- swapMVar    pendingResps    err
    unblockAll m
    mtid <- tryTakeMVar listenerThread
    case mtid of
      Nothing -> return () -- thread killed by 'closeManager'
      Just _  -> return () -- thread killed by exception from 'listen'
    return ()
  where
    err = error "UDP tracker manager closed"
-- 开启UDP端口进行监听，如果出现问题则进行resetState
-- | This function will throw 'IOException' on invalid 'Options'.
newManager :: Options -> IO Manager
newManager opts = do
  checkOptions opts
  mgr <- initManager opts
  tid <- forkIO (listen mgr `finally` resetState mgr)
  putMVar (listenerThread mgr) tid
  return mgr

-- | Unblock all RPCs by throwing 'ManagerClosed' exception. No rpc
-- calls should be performed after manager becomes closed.
closeManager :: Manager -> IO ()
closeManager Manager {..} = do
  close sock
  mtid <- tryTakeMVar listenerThread
  case mtid of
    Nothing  -> return ()
    Just tid -> killThread tid

-- | Normally you need to use 'Control.Monad.Trans.Resource.allocate'.
withManager :: Options -> (Manager -> IO a) -> IO a
withManager opts = bracket (newManager opts) closeManager

{-----------------------------------------------------------------------
--  Exceptions
-----------------------------------------------------------------------}

data RpcException
    -- | Unable to lookup hostname;
  = HostUnknown

    -- | Unable to lookup hostname;
  | HostLookupFailed

    -- | Expecting 'udp:', but some other scheme provided.
  | UnrecognizedScheme String

    -- | Tracker exists but not responding for specific number of seconds.
  | TimeoutExpired Int

    -- | Tracker responded with unexpected message type.
  | UnexpectedResponse
    { expectedMsg :: String
    , actualMsg   :: String
    }

    -- | RPC succeed, but tracker responded with error code.
  | QueryFailed Text

    -- | RPC manager closed while waiting for response.
  | ManagerClosed
    deriving (Eq, Show, Typeable)

instance Exception RpcException

{-----------------------------------------------------------------------
--  Host Addr resolution
-----------------------------------------------------------------------}

setPort :: PortNumber -> SockAddr -> SockAddr
setPort p (SockAddrInet  _ h)     = SockAddrInet  p h
setPort p (SockAddrInet6 _ f h s) = SockAddrInet6 p f h s
setPort _  addr = addr

resolveURI :: URI -> IO SockAddr
resolveURI URI { uriAuthority = Just (URIAuth {..}) } = do
  infos <- getAddrInfo Nothing (Just uriRegName) Nothing
  let port = fromMaybe 0 (readMaybe (L.drop 1 uriPort) :: Maybe Int)
  case infos of
    AddrInfo {..} : _ -> return $ setPort (fromIntegral port) addrAddress
    _                 -> throwIO HostLookupFailed
resolveURI _       = throwIO HostUnknown

-- TODO caching?
getTrackerAddr :: Manager -> URI -> IO SockAddr
getTrackerAddr _ uri
  | uriScheme uri == "udp:" = resolveURI uri
  |        otherwise        = throwIO (UnrecognizedScheme (uriScheme uri))

{-----------------------------------------------------------------------
  Connection
-----------------------------------------------------------------------}

connectionLifetime :: NominalDiffTime
connectionLifetime = 60

data Connection = Connection
  { connectionId        :: ConnectionId
  , connectionTimestamp :: UTCTime
  } deriving Show

-- placeholder for the first 'connect'
initialConnection :: Connection
initialConnection = Connection initialConnectionId (posixSecondsToUTCTime 0)

establishedConnection :: ConnectionId -> IO Connection
establishedConnection cid = Connection cid <$> getCurrentTime

isExpired :: Connection -> IO Bool
isExpired Connection {..} = do
  currentTime <- getCurrentTime
  let timeDiff = diffUTCTime currentTime connectionTimestamp
  return $ timeDiff > connectionLifetime

{-----------------------------------------------------------------------
--  Transactions
-----------------------------------------------------------------------}

-- | Sometimes 'genTransactionId' may return already used transaction
-- id. We use a good entropy source but the issue /still/ (with very
-- small probabality) may happen. If the collision happen then this
-- function tries to find nearest unused slot, otherwise pending
-- transactions table is full.
firstUnused :: SockAddr -> TransactionId -> PendingQueries -> TransactionId
firstUnused addr rid m = do
  case M.splitLookup rid <$> M.lookup addr m of
    Nothing                -> rid
    Just (_ , Nothing, _ ) -> rid
    Just (lt, Just _ , gt) ->
      case backwardHole (keys lt) rid <|> forwardHole rid (keys gt) of
        Nothing  -> error "firstUnused: table is full" -- impossible
        Just tid -> tid
  where
    forwardHole a []
      | a == maxBound = Nothing
      |   otherwise   = Just (succ a)
    forwardHole a (b : xs)
      | succ a == b   = forwardHole b xs
      |   otherwise   = Just (succ a)

    backwardHole [] a
      | a == minBound = Nothing
      |   otherwise   = Just (pred a)
    backwardHole (b : xs) a
      | b == pred a   = backwardHole xs b
      |   otherwise   = Just (pred a)

register :: SockAddr -> TransactionId -> PendingResponse
         -> PendingQueries -> PendingQueries
register addr tid ares = M.alter insertId addr
  where
    insertId Nothing  = Just (M.singleton tid ares)
    insertId (Just m) = Just (M.insert tid ares m)

unregister :: SockAddr -> TransactionId
           -> PendingQueries -> PendingQueries
unregister addr tid = M.update deleteId addr
  where
    deleteId m
      | M.null m' = Nothing
      | otherwise = Just m'
      where
        m' = M.delete tid m

-- | Generate a new unused transaction id and register as pending.
allocTransaction :: Manager -> SockAddr -> PendingResponse -> IO TransactionId
allocTransaction Manager {..} addr ares =
  modifyMVar pendingResps $ \ m -> do
    rndId <- genTransactionId
    -- 此处得到一个transaction的ID
    let tid = firstUnused addr rndId m
    return (register addr tid ares m, tid)

-- | Wake up blocked thread and return response back.
commitTransaction :: Manager -> SockAddr -> TransactionId -> Response -> IO ()
commitTransaction Manager {..} addr tid resp =
  modifyMVarMasked_ pendingResps $ \ m -> do
    case M.lookup tid =<< M.lookup addr m of
      Nothing   -> return m -- tracker responded after 'cancelTransaction' fired
      Just ares -> do
        putMVar ares (Right resp)
        return $ unregister addr tid m

-- | Abort transaction forcefully.
cancelTransaction :: Manager -> SockAddr -> TransactionId -> IO ()
cancelTransaction Manager {..} addr tid =
  modifyMVarMasked_ pendingResps $ \m ->
    return $ unregister addr tid m
-- 此处死循环，不过ForkIO也是轻量级的线程
-- 也就是一个数据块
-- | Handle responses from trackers.
listen :: Manager -> IO ()
listen mgr @ Manager {..} = do
  forever $ do
    (bs, addr) <- BS.recvFrom sock (optMaxPacketSize options)
    case decode bs of
      Left  _                   -> return () -- parser failed, ignoring
      Right (TransactionR {..}) -> commitTransaction mgr addr transIdR response

-- | Perform RPC transaction. If the action interrupted transaction
-- will be aborted.
transaction :: Manager -> SockAddr -> Connection -> Request -> IO Response
transaction mgr @ Manager {..} addr conn request = do
    ares <- newEmptyMVar
    tid  <- allocTransaction mgr addr ares
    performTransaction tid ares
      `onException` cancelTransaction mgr addr tid
  where
    performTransaction tid ares = do
      let trans = TransactionQ (connectionId conn) tid request
      BS.sendAllTo sock (encode trans) addr
      takeMVar ares >>= either throwIO return

{-----------------------------------------------------------------------
--  Connection cache
-----------------------------------------------------------------------}

connect :: Manager -> SockAddr -> Connection -> IO ConnectionId
connect m addr conn = do
  resp <- transaction m addr conn Connect
  case resp of
    Connected cid -> return cid
    Failed    msg -> throwIO $ QueryFailed msg
    _ -> throwIO $ UnexpectedResponse "connected" (responseName resp)
-- 向远端发起链接请求，并得到链接的ID
newConnection :: Manager -> SockAddr -> IO Connection
newConnection m addr = do
  connId  <- connect m addr initialConnection
  establishedConnection connId

refreshConnection :: Manager -> SockAddr -> Connection -> IO Connection
refreshConnection mgr addr conn = do
  expired <- isExpired conn
  if expired
    then do
      connId <- connect mgr addr conn
      establishedConnection connId
    else do
      return conn

withCache :: Manager -> SockAddr
          -> (Maybe Connection -> IO Connection) -> IO Connection
withCache mgr addr action = do
  cache <- readIORef (connectionCache mgr)
  conn  <- action (M.lookup addr cache)
  writeIORef (connectionCache mgr) (M.insert addr conn cache)
  return conn
-- 拿到相应的链接
-- 此处要么新建一个，要么刷新
getConnection :: Manager -> SockAddr -> IO Connection
getConnection mgr addr = withCache mgr addr $
  maybe (newConnection mgr addr) (refreshConnection mgr addr)

{-----------------------------------------------------------------------
--  RPC
-----------------------------------------------------------------------}

retransmission :: Options -> IO a -> IO a
retransmission Options {..} action = go optMinTimeout
  where
    go curTimeout
      | curTimeout > optMaxTimeout = throwIO $ TimeoutExpired curTimeout
      |         otherwise          = do
        r <- timeout (curTimeout * sec) action
        maybe (go (optMultiplier * curTimeout)) return r
-- 向Tracker发起请求
queryTracker :: Manager -> URI -> Request -> IO Response
queryTracker mgr uri req = do
  -- 得到Tracker的地址
  addr <- getTrackerAddr mgr uri

  retransmission (options mgr) $ do
    conn <- getConnection  mgr addr
    -- 得到链接后，直接开始进行发送
    -- 此处的链接只是IP:Port:Query形式的东西，并非UDP连接
    transaction mgr addr conn req

-- | This function can throw 'RpcException'.
announce :: Manager -> URI -> AnnounceQuery -> IO AnnounceInfo
announce mgr uri q = do
  resp <- queryTracker mgr uri (Announce q)
  case resp of
    Announced info -> return info
    _ -> throwIO $ UnexpectedResponse "announce" (responseName resp)

-- | This function can throw 'RpcException'.
scrape :: Manager -> URI -> ScrapeQuery -> IO ScrapeInfo
scrape mgr uri ihs = do
  resp <- queryTracker mgr uri (Scrape ihs)
  case resp of
    Scraped info -> return $ L.zip ihs info
    _ -> throwIO $ UnexpectedResponse "scrape" (responseName resp)
