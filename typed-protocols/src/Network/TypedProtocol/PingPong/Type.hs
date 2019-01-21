{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds    #-}
{-# LANGUAGE EmptyCase    #-}
{-# LANGUAGE GADTs        #-}
{-# LANGUAGE PolyKinds    #-}
{-# LANGUAGE RankNTypes   #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wall -Wno-unticked-promoted-constructors #-}

module Network.TypedProtocol.PingPong.Type where

import           Network.TypedProtocol.Core


-- | States in the ping pong system.
data PingPongState where
  StIdle :: PingPongState
  StBusy :: PingPongState
  StDone :: PingPongState

instance Protocol PingPongState where

  -- | We have to explain to the framework what our states mean, in terms of
  -- who is expected to send and receive in the different states.
  --
  -- Idle states are where it is for the client to send a message,
  -- busy states are where the server is expected to send a reply.
  --
  type AgencyInState StIdle = ClientHasAgency
  type AgencyInState StBusy = ServerHasAgency
  type AgencyInState StDone = NobodyHasAgency

  -- | The actual messages in our protocol.
  --
  -- These involve transitions between different states within the 'StPingPong'
  -- states. A ping request goes from idle to busy, and a pong response go from
  -- busy to idle.
  --
  -- This example is so simple that we have all the messages directly as
  -- constructors within this type. In more complex cases it may be better to
  -- factor all (or related) requests and all responses within one case (in
  -- which case the state transitions may depend on the particular message via
  -- the usual GADT tricks).
  --
  data Message from to where
    MsgPing :: Message StIdle StBusy
    MsgPong :: Message StBusy StIdle
    MsgDone :: Message StIdle StDone

  data ClientToken st where
    ClientTokenIdle :: ClientToken StIdle

  data ServerToken st where
    ServerTokenBusy :: ServerToken StBusy

  data TerminalToken st where
    TerminalTokenDone :: TerminalToken StDone


instance Show (Message (from :: PingPongState) (to :: PingPongState)) where
  show MsgPing = "MsgPing"
  show MsgPong = "MsgPong"
  show MsgDone = "MsgDone"

impossibleProofs :: ImpossibleProofs PingPongState
impossibleProofs = ImpossibleProofs {
    noYieldingDeadlock = \ClientTokenIdle server -> case server of {},
    noAwaitingDeadlock = \ClientTokenIdle server -> case server of {},
    notPartiallyFinished = \TerminalTokenDone choice -> case choice of
      Left client  -> case client of {}
      Right server -> case server of {}
  }
