module Main where

import Data.Char (toUpper)
import System.IO
import Control.Exception
import Network.Socket
import Control.Concurrent
import Control.Monad (when, forM, mapM)
import Control.Monad.Fix (fix)
import qualified Data.Map as Map

data User = User {
    userId :: Int,
    nick :: String,
    host :: String,
    userChannels :: [String],
    localBus :: Chan Event
}

instance Show User where
    show u = (nick u) ++ "@" ++ (host u) ++ "#" ++ ((show . userId) u) ++ "?channels=" ++ (show (userChannels u))

data Channel = Channel {
    channelName :: String,
    channelUsers :: [Int]
} deriving (Show)

data ServerState = ServerState {
    users :: Map.Map Int User,
    channels :: Map.Map String Channel
}

data Event = NewUser User |
             UserEvent User Command
             deriving (Show)

data Command = Nick String |
               UserCommand String Int String |
               Join String |
               Part String |
               PrivMsg String String |
               -- WHOIS
               -- NAMES
               -- TOPIC
               -- MODE
               -- KICK
               Quit String
               deriving (Show)

parseMsg :: [String] -> String
parseMsg msg@((':':_):_) = tail $ unwords msg
parseMsg (f:fx) = f

parseCommand :: String -> Maybe Command
parseCommand msg = case (command, args) of
        ("NICK", (nick:_)) -> Just (Nick nick)
        ("USER", (user:mode:_:realname)) -> Just (UserCommand user (read mode) (parseMsg realname))
        ("JOIN", (channel:_)) -> Just (Join channel)
        ("PART", (channel:_)) -> Just (Part channel)
        ("PRIVMSG", (channel:msg)) -> Just (PrivMsg channel (parseMsg msg))
        ("QUIT", msg) -> Just (Quit (parseMsg msg))
        _ -> Nothing
    where parts = words msg
          command = map toUpper $ head parts
          args = tail parts

processIdentification :: Int -> (Handle, SockAddr) -> Chan Event -> IO User
processIdentification userId (hdl, addr) localBus = gather Nothing Nothing
    where gather :: Maybe String -> Maybe (String, Int, String) -> IO User
          gather (Just nick) (Just (user, mode, realName)) = return User {
                userId = userId,
                nick = nick,
                host = (show addr),
                userChannels = [],
                localBus = localBus
          }
          gather nickState userState = do
            command <- hGetLine hdl
            case (parseCommand command) of
                Just (Nick nick) -> gather (Just nick) userState
                Just (UserCommand user mode realName) -> gather nickState (Just (user, mode, realName))
                _ -> do
                    hPutStrLn hdl "Expected NICK or USER"
                    gather nickState userState

processChannelEvent :: Map.Map String Channel -> Event -> Map.Map String Channel
processChannelEvent channels (UserEvent user (Join channelName)) =
    let update key old = old {
             channelUsers = [userId user] ++ (channelUsers old)
        }
        newChannel = Channel {
            channelName = channelName,
            channelUsers = [userId user]
        }
    in Map.insertWith update channelName newChannel channels
processChannelEvent channels (UserEvent user (Part channelName)) =
    let notThisUser u = u /= (userId user)
        updateChannel channel = channel {
             channelUsers = filter notThisUser (channelUsers channel)
        }
        update channel = fmap updateChannel channel
    in Map.alter update channelName channels
processChannelEvent channels (UserEvent user (Quit _)) =
    let notThisUser u = u /= (userId user)
        updateChannel channel = channel {
             channelUsers = filter notThisUser (channelUsers channel)
        }
        update channel = fmap updateChannel channel
    in foldl (\channels channelName -> Map.alter update channelName channels) channels (userChannels user)
processChannelEvent channels _ = channels

processUserEvent :: Map.Map Int User -> Event -> Map.Map Int User
processUserEvent users (NewUser user) = Map.insert (userId user) user users

-- The internal list of channels for a user is updated in the per-user command
-- handler, so we just need to update the existing object
processUserEvent users (UserEvent user (Join _)) = Map.insert (userId user) user users
processUserEvent users (UserEvent user (Part _)) = Map.insert (userId user) user users

processUserEvent users _ = users

processMessages :: ServerState -> Event -> IO [()]
processMessages state event@(UserEvent user (PrivMsg channelName text)) =
    forM (usersInChannel channel) $ \user -> do
        putStrLn ("Sending message " ++ (show event) ++ " to " ++ (show user))
        writeChan (localBus user) event
    where channel = Map.lookup channelName (channels state)
          getUser u = Map.lookup u (users state)
          usersInChannel Nothing = []
          usersInChannel (Just channel) = [ u | Just u <- map getUser (channelUsers channel) ]

processMessages users _ = return [()]

processEvent :: Chan Event -> ServerState -> IO ()
processEvent events state = do
    event <- readChan events
    let newChannels = processChannelEvent (channels state) event
    let newUsers = processUserEvent (users state) event
    putStrLn $ show event
    putStrLn $ show newUsers
    putStrLn $ show newChannels
    processMessages state event
    processEvent events ServerState {
        users = newUsers,
        channels = newChannels
    }

main :: IO ()
main = do
    sock <- socket AF_INET Stream 0
    setSocketOption sock ReuseAddr 1
    bind sock (SockAddrInet 4242 0)
    listen sock 2
    eventBus <- newChan
    let state = ServerState {
        users = Map.empty,
        channels = Map.empty
    }
    _ <- forkIO $ processEvent eventBus state
    mainLoop 0 sock eventBus

mainLoop :: Int -> Socket -> Chan Event -> IO ()
mainLoop nextUserId sock eventBus = do
    conn <- accept sock
    forkIO (runConn nextUserId conn eventBus)
    mainLoop (nextUserId + 1) sock eventBus

runConn :: Int -> (Socket, SockAddr) -> Chan Event -> IO ()
runConn userId (sock, addr) eventBus = do
    let sendEvent msg = writeChan eventBus msg
    hdl <- socketToHandle sock ReadWriteMode
    hSetBuffering hdl NoBuffering

    localEvents <- newChan
    localEventsTx <- dupChan localEvents

    user <- processIdentification userId (hdl, addr) localEventsTx
    sendEvent (NewUser user)

    localReader <- forkIO $ fix $ \loop -> do
        msg <- readChan localEvents
        hPutStrLn hdl $ show msg
        loop

    let resetHandler (SomeException _) = return (Just (Quit "Connection reset by peer"))
        inputHandler user = do
            command <- handle resetHandler $ fmap parseCommand $ hGetLine hdl
            case command of
                Just cmd@(Quit _) -> return (UserEvent user cmd)
                Just cmd@(Join channel) -> do
                    sendEvent (UserEvent user cmd)
                    inputHandler user {
                        userChannels = (userChannels user) ++ [channel]
                    }
                Just cmd@(Part channel) -> do
                    sendEvent (UserEvent user cmd)
                    inputHandler user {
                        userChannels = filter (\c -> c /= channel) (userChannels user)
                    }
                Just cmd -> do
                    sendEvent (UserEvent user cmd)
                    inputHandler user
                _ -> do
                    hPutStrLn hdl "Invalid command"
                    inputHandler user

    quitEvent <- inputHandler user

    killThread localReader
    sendEvent quitEvent
    hClose hdl
