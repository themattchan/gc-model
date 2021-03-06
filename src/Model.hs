{-# LANGUAGE
ExistentialQuantification, GADTs,
DataKinds,KindSignatures,TypeFamilies, RankNTypes,ConstraintKinds,
UndecidableInstances,TypeSynonymInstances, FlexibleInstances,
Strict, TypeApplications
#-}

-- prototype implementation of rc-gc
module Model where

import Control.Monad
import Control.Monad.Except
import Control.Monad.State.Lazy
import Control.Monad.Trans
import Control.Concurrent
import Data.Array.IO
import Data.Array.MArray
--import Data.Binary hiding (get, put)
import Data.Bits
import Data.Char
import Data.IORef
import Data.Proxy
import Data.Word
import Foreign.Marshal.Alloc
import Foreign.Ptr
import Foreign.Storable
import System.IO

import Control.Monad.Primitive
import Data.Primitive.ByteArray
import Test.QuickCheck hiding ((.&.))
import Numeric

import Control.Monad.ST
import Data.Function
import Data.List
import Data.Ord

-- fit in word64
-- top 32 bits is metadata, bottom 32 bits is data
--   - data can be 16 bit pointer, in which case high-order 16 bits must be 0
--   - data can be 32 bit unsigned integer
-- top 16 bits of metadata is forwarding pointer if it exists
-- bottom 16 bits of metadata is tags:
--
-- invariant:

--data Data      = Int Word32 | Ptr Word16
data Type = Int | Ptr deriving (Show, Eq)
data HeapEntry = HeapEntry Word16 -- ^ forwarding pointer
                           Type   -- ^ type
                           Bool   -- ^ GC bit
                           Word32 -- ^ Data
  deriving (Show, Eq)


serialize :: HeapEntry -> Word64
serialize (HeapEntry f t g d) =  ((shift (fromIntegral f)             48)
                             .|. (shift (fromIntegral otherMetadata) 32))
                             .|. fromIntegral data'
  where data' | t == Int     = d
              | t == Ptr = d .&. 0xffff
        otherMetadata :: Word16
        otherMetadata =  shift (fromIntegral typeRepr) 1
                     .|. shift (fromIntegral gcRepr)   0
        typeRepr :: Word16
        typeRepr | t == Int     = 0
                 | t == Ptr = 1
        gcRepr :: Word16
        gcRepr | g == False = 0
               | g == True = 1
deserialize :: Word64 -> HeapEntry
deserialize w = HeapEntry f t g d
  where f = fromIntegral $ shift w (-48)
        t = if w .&. 0x200000000 > 0 then Ptr else Int
        g = if w .&. 0x100000000 > 0 then True else False
        d = fromIntegral $ w .&. (case t of
                                    Int -> 0xffffffff
                                    Ptr -> 0xffff)

p :: (Show a, Integral a) => a -> String
p = flip showHex ""

instance Arbitrary Type where
  arbitrary = elements [Int, Ptr]

instance Arbitrary HeapEntry where
  arbitrary = do
    f <- arbitrary
    t <- arbitrary
    g <- arbitrary
    d <- case t of
      Int -> arbitrary @Word32
      Ptr -> fromIntegral <$> arbitrary @Word16
    return $ (HeapEntry f t g d)

prop_serialize_bidirectional :: HeapEntry -> Bool
prop_serialize_bidirectional h = h == (deserialize . serialize) h

type HeapPtr = Word16
{-data Thread = Thread HeapPtr -- ^ The start of its free blocks list
                     HeapPtr -- ^ The bottom of its stack
                     HeapPtr -- ^ The top of its stack-}
type Thread = Bool -- ^ is this the 1st thread or the 2nd

--invariant for global free blocks list:
--
--  IOref of some integer
--  every number preceding it is filled
--
-- actually there will be no free blocks list for now.

-- each block is 1K

-- PSA suggestion on simple thing to start with
--
-- we have only two thread
-- each thread has its own blocks list
-- each thread "owns" half of memory
--
-- thread 1 can put whatever it wants inside 0x0000 to 0x7FFF
-- thread 2 can put whatever it wants inside 0x8000 to 0xFFFF


type RTS m = StateT (Heap m) m

runRTS :: Monad m => Heap m -> RTS m a -> m a
runRTS = flip evalStateT

{-runOneThread' :: forall s. RTS (ST s) ()
runOneThread' = do
  undefined

runOneThread :: forall s. Heap (ST s) -> ST s ()
runOneThread s = runRTS s runOneThread'

main :: IO ()
main = do
  heap' <- newByteArray (8 * 0xFFFF)
  let heap = Heap { heapMem = heap' }
  forkIO $ runST $ runOneThread heap
  forkIO $ runST $ runOneThread heap-}

{-threadBase :: Thread -> HeapPtr
threadBase False = 0x0000
threadBase True  = 0x8000

setupThread :: HeapPtr -> RTS IO ()
setupThread threadBase = do
  undefined-}

fullHeap :: RTS IO Bool
fullHeap = null . unFreeList <$> gets freeList

splitLowestByte :: FreeList -> (HeapPtr, FreeList)
splitLowestByte (FreeList f) = (el, FreeList new)
  where (Interval el eh:es) = sortBy (compare `on` iLow) $ f
        el' = el + 1
        new | el' == eh = es
            | otherwise = Interval el' eh:es

alloc :: HeapEntry -> RTS IO ()
alloc e = do
  f <- fullHeap
  if f then gcThisThread else do
    h <- get
    let (addr, f') = splitLowestByte (freeList h)
    writeByteArray (heapMem h) (fromIntegral addr) (serialize e)
    put h { freeList = f' }

gcThisThread :: RTS IO ()
gcThisThread = undefined

runOneThread :: Bool -> RTS IO ()
runOneThread t = do
  undefined

main :: IO ()
main = do
  heap' <- newByteArray (8 * 0xFFFF)
  forkOS $ evalStateT (runOneThread False) $
    Heap { heapMem = heap'
         , heapRootSet = []
         , freeList = FreeList [Interval 0x0001 0x7FFF ]
         }
  forkOS $ evalStateT (runOneThread True) $
    Heap { heapMem = heap'
         , heapRootSet = []
         , freeList = FreeList [Interval 0x8001 0xFFFF ]
         }
  forever $ threadDelay 100000000000


-- other structures to consider:
--   rose tree of IORefs / Ptr Word32

data Interval = Interval { iLow :: HeapPtr, iHigh :: HeapPtr }
newtype FreeList = FreeList { unFreeList :: [Interval] }

data Heap m = Heap
  -- this is NOT block structured!!!
  { heapMem      :: MutableByteArray (PrimState m)
  , heapRootSet :: [HeapPtr]
  , freeList    :: FreeList
  -- , heapBounds :: (Int,Int)     -- array bounds
  -- , heapFree :: Int             -- next free index
  }

{- data TypeTag = Pointer | Int


-- TODO: throw memory exhaustion exception
-- GC = catch exception, run gc, etc
data Exn = OutOfMemory
         | InvalidPtr -- if not tagged as a metadata field

type RTS a = ExceptT Exn (StateT Heap IO) a

withRawHeap :: (IOUArray Int Word32 -> IO a) -> RTS a
withRawHeap f = gets heapMem >>= liftIO . f

getAllocPtr :: RTS Int
getAllocPtr = gets heapFree

bumpAllocPtr :: Int -> RTS ()
bumpAllocPtr i = void $ modify (\h -> h {heapFree = heapFree h + i})

writeWords :: [Word32] -> RTS Int
writeWords ws = do
  i <- getAllocPtr
  bumpAllocPtr (length ws)
  withRawHeap $ \h -> zipWithM_ (writeArray h) [i..] ws
  return i

-- given an int index, get its metadata
getType :: Int -> RTS (Proxy x)
getType i = do
  meta <- withRawHeap $ \h -> readArray h i
  checkIsMeta meta
  return $ metaType meta

-- TODO
checkIsMeta :: Word32 -> RTS ()
checkIsMeta w = throwError InvalidPtr

metaType :: Word32 -> Proxy x
metaType = undefined


alloc ::-}

-- -- | DATA REPRESENTATION
-- -- right now only consider primitive data that fit into a single word32.
-- -- heap looks like this:
-- --      [meta | data | meta | data ... ]
-- --
-- -- tagging: use LSB for tagging:
-- -- 0 for metadata
-- -- 1 for data
-- --
-- -- NB: as this gets fleshed out it will be time to switch to a better repr like
-- -- the GHC representation: https://ghc.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/HeapObjects
-- -- or the Scheme one: http://www.more-magic.net/posts/internals-data-representation.html




-- -- proxy for metadata serialisation
-- data Meta

-- -- representable data
-- newtype Var v a = Var v

-- data Value v a where
--   Fun :: (Var v a -> Value v b) -> Value v b
--   Let :: Var v a -> Value v a -> Value v b -> Value v b
--   Bool :: Bool -> Value v Bool
--   Int :: Int -> Value v Int


-- --  Int  :: Int -> Value
-- --  Chr  ::  -> Value
-- --  Bool :: Word32 -> Value

-- --  Meta :: Word32 -> Value (Proxy Meta)
-- --  Pair :: Value a -> Value b -> Value x

-- -- serialisation
-- class Repr x where
--   repr :: x -> [Word32]

--   meta :: x -> Word32

-- -- TODO
-- instance Repr (Value x) where
--   repr (Int i) = [0]

--   meta (Int i) = 0

-- serialise :: Repr a => a -> [Word32]
-- serialise x = meta x : repr x

-- {-@ reify :: {b:[Word32]| len b >= 2} -> Proxy x -> Value x @-}
-- reify :: [Word32] -> Proxy x -> Value x
-- reify (m:bs) _ = undefined

-- alloc :: Repr a => a -> GC a
-- alloc x = do
--   let r = meta x : repr x
--   return x


-- compile arbitrary haskell progs
-- class Embed a where
--   embed :: a -> Value
-- instance Embed Int where
--   embed i = Int i
-- instance Embed String where
--   embed s = Str s
-- instance Embed Bool where
--   embed b = Bool b
-- instance (Embed a, Embed b) => Embed (a,b) where
--   embed (a,b) = Pair (embed a) (embed b)

-- class CoEmbed a where
--   embedFun :: a -> (Value -> Value)

-- instance (Embed a, Embed b) => CoEmbed (a -> b) where
--   embedFun f = \x -> embed (f (unembed x))

-- instance (Embed a, CoEmbed b, b ~ (c -> d)) => CoEmbed (a -> b) where
--   embedFun f = \x -> embed (f (unembed x))
--     where
--       unembed :: Value -> a
--       unembed (Int i) = i
--       unembed (Str s) = s
--       unembed (Bool b) = b


-- gc semantics




-- main :: IO ()
-- main = do
--   return ()
