{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Network.TypedProtocol.PingPong.Client where

import           Data.Functor (($>))
import           Numeric.Natural (Natural)

import           Control.Monad.Class.MonadSTM (MonadSTM (..))

import           Network.TypedProtocol.Core
import qualified Network.TypedProtocol.Pipelined as Pipelined
import           Network.TypedProtocol.PingPong.Type

-- | A ping-pong client, on top of some effect 'm'.
--
-- At each step the client has a choice: ping or stop.
--
-- This type encodes the pattern of state transitions the client can go through.
-- For the ping\/pong case this is trivial. We start from one main state,
-- issue a ping and move into a state where we expect a single response,
-- bringing us back to the same main state.
--
-- If we had another state in which a different set of options were available
-- then we would need a second type like this. The two would be mutually
-- recursive if we can get in both directions, or perhaps just one way such
-- as a special initialising state or special terminating state.
--
data PingPongClient m a where
  -- | Choose to go for sending a ping message. The ping has no body so
  -- all we have to provide here is a continuation for the single legal
  -- reply message.
  --
  SendMsgPing    :: m (PingPongClient m a) -- continuation for Pong response
                 -> PingPongClient m a

  -- | Choose to terminate the protocol. This is an actual but nullary message,
  -- we terminate with the local result value. So this ends up being much like
  -- 'return' in this case, but in general the termination is a message that
  -- can communicate final information.
  --
  SendMsgDone    :: a -> PingPongClient m a


-- | An example ping-pong client that sends pings as fast as possible forever‽
--
-- This may not be a good idea‼
--
pingPongClientFlood :: Applicative m => PingPongClient m a
pingPongClientFlood = SendMsgPing (pure pingPongClientFlood)

-- | An example ping-pong client that sends a fixed number of ping messages
-- and then stops.
--
pingPongClientCount
  :: Applicative m
  => Natural
  -> PingPongClient m ()
pingPongClientCount 0 = SendMsgDone ()
pingPongClientCount m = SendMsgPing $ pure (pingPongClientCount (pred m))

-- | Interpret a particular client action sequence into the client side of the
-- 'PingPong' protocol.
--
pingPongClientPeer
  :: Monad m
  => PingPongClient m a
  -> Peer AsClient StIdle m a

pingPongClientPeer (SendMsgDone result) =
    -- We do an actual transition using 'yield', to go from the 'StIdle' to
    -- 'StDone' state. Once in the 'StDone' state we can actually stop using
    -- 'done', with a return value.
    yield ClientTokenIdle MsgDone (done TerminalTokenDone result)

pingPongClientPeer (SendMsgPing next) =

    -- Send our message.
    yield ClientTokenIdle MsgPing $

    -- The type of our protocol means that we're now into the 'StBusy' state
    -- and the only thing we can do next is local effects or wait for a reply.
    -- We'll wait for a reply.
    await ServerTokenBusy $ \MsgPong ->

    -- Now in this case there is only one possible response, and we have
    -- one corresponding continuation 'kPong' to handle that response.
    -- The pong reply has no content so there's nothing to pass to our
    -- continuation, but if there were we would.
      effect $ do
        client <- next
        pure $ pingPongClientPeer client

-- |
-- A ping-pong client designed for running piplined ping-pong protocol.
--
data PingPongSender m a where
  -- | 
  -- Send a `Ping` message but alike in `PingPongClient` do not await for the
  -- resopnse, instead supply a monadic action which will run on a received
  -- `Pong` message.
  SendMsgPingPipelined
    :: m ()               -- receive action
    -> PingPongSender m a -- continuation
    -> PingPongSender m a

  -- | Termination of the ping-pong protocol.
  SendMsgDonePipelined
    :: a -> PingPongSender m a

pingPongSenderCount
  :: MonadSTM m
  => TVar m Natural
  -> Natural
  -> PingPongSender m ()
pingPongSenderCount var = go
 where
  go 0 = SendMsgDonePipelined ()
  go n = SendMsgPingPipelined
    (atomically $ modifyTVar var succ)
    (go (pred n))

pingPongClientPeerSender
  :: Monad m
  => PingPongSender m a
  -> Pipelined.PeerSender AsClient StIdle m a

pingPongClientPeerSender (SendMsgDonePipelined result) =
  -- Send `MsgDone` and complete the protocol
  Pipelined.complete ClientTokenIdle TerminalTokenDone MsgDone result

pingPongClientPeerSender (SendMsgPingPipelined receive next) =
  -- Piplined yield: send `MsgPing`, imediatelly follow with the next step.
  -- Await for a response in a continuation.
  Pipelined.yield
    ClientTokenIdle
    MsgPing
    -- response handler
    (Pipelined.await ServerTokenBusy $ \MsgPong -> Pipelined.effect' $ receive $> Pipelined.Completed)
    -- run the next step of the ping-pong protocol.
    (Pipelined.effect $ return $ pingPongClientPeerSender next)