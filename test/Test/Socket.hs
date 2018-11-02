{-# OPTIONS_GHC -Wno-orphans #-}
module Test.Socket (tests) where

import           Block (Block, Slot(..), HeaderHash(..))
import           Chain (Point(..), Chain(..))
import           Protocol
import           Socket (demo2)
import           Serialise (prop_serialise)

import Test.Chain (TestBlockChainAndUpdates(..), genBlockChain)

import Test.QuickCheck
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)

--
-- The list of all tests
--

tests :: TestTree
tests =
  testGroup "Socket"
  [ testProperty "serialise MsgConsumer" prop_serialise_MsgConsumer
  , testProperty "serialise MsgProducer" prop_serialise_MsgProducer
  , testProperty "socket sync demo"        prop_socket_demo
  ]


--
-- Properties
--

prop_socket_demo :: TestBlockChainAndUpdates -> Property
prop_socket_demo (TestBlockChainAndUpdates chain updates) =
    ioProperty $ demo2 chain updates

prop_serialise_MsgConsumer :: MsgConsumer -> Bool
prop_serialise_MsgConsumer = prop_serialise

prop_serialise_MsgProducer :: MsgProducer Block -> Bool
prop_serialise_MsgProducer = prop_serialise

instance Arbitrary MsgConsumer where
  arbitrary = oneof [ pure MsgRequestNext
                    , MsgSetHead <$> arbitrary
                    ]

instance Arbitrary block => Arbitrary (MsgProducer block) where
  arbitrary = oneof [ MsgRollBackward <$> arbitrary
                    , MsgRollForward  <$> arbitrary
                    , pure MsgAwaitReply
                    , MsgIntersectImproved <$> arbitrary <*> arbitrary
                    , pure MsgIntersectUnchanged
                    ]

instance Arbitrary Point where
  arbitrary = Point <$> (Slot <$> arbitraryBoundedIntegral)
                    <*> (HeaderHash <$> arbitraryBoundedIntegral)

instance Arbitrary Block where
  arbitrary = do _ :> b <- genBlockChain 1
                 return b

