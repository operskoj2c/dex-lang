module Table (Table, fromScalar, diag, map, map2, iota, printTable) where

import Prelude hiding (map, lookup)
import Data.List (intersperse, transpose)
import qualified Prelude as P
import qualified Data.Map.Strict as M

data Idx a = Only a | Anything
data Comparison a = LeftSmall | RightSmall | Match a Ordering
newtype Table a b = Table (Rows a b)
type Rows a b = [([Idx a], b)]

fromScalar :: Ord a => b -> Table a b
fromScalar x = Table [([], x)]

map ::  Ord k => (a -> b) -> Table k a -> Table k b
map f (Table rows) = Table (P.map (second f) rows)

second :: (a -> b) -> (c, a) -> (c, b)
second f (x, y) = (x, f y)

map2 :: Ord k => (a -> b -> c) -> Table k a -> Table k b -> Table k c
map2 f (Table rows1) (Table rows2) = Table $ map2' f rows1 rows2

map2' :: Ord k => (a -> b -> c) -> Rows k a -> Rows k b -> Rows k c
map2' f [] _ = []
map2' f _ [] = []
map2' f ((k1,v1):rem1) ((k2,v2):rem2) =
  let cur1 = (k1,v1):rem1
      cur2 = (k2,v2):rem2
      (match, rest1, rest2) =
        case cmpIdxs k1 k2 of
          LeftSmall  -> (Nothing, rem1, cur2)
          RightSmall -> (Nothing, cur1, rem2)
          Match k LT -> (Just k , rem1, cur2)
          Match k GT -> (Just k , cur1, rem2)
          Match k EQ -> (Just k , rem1, rem2)
      rest = map2' f rest1 rest2
   in case match of
        Nothing -> rest
        Just k  -> (k, f v1 v2):rest

iota :: Table Int Int -> Table Int Int
iota (Table rows) = Table [((Only i):k, i) | (k,v) <- rows, i <- [0..(v-1)]]

diag :: Ord k => Table k a -> Int -> Int -> Table k a
diag (Table rows) i j = Table $ diag' rows i j

diag' :: Ord k => Rows k a -> Int -> Int -> Rows k a
diag' [] _ _ = []
diag' ((kraw,v):rem) i j =
  let rest = diag' rem i j
      k = pad (j + 1) Anything kraw
  in case cmpIdx (k!!i) (k!!j) of
       Nothing -> rest
       Just idx -> let k' = delIdx i . replaceIdx j idx $ k
                   in (k',v):rest

pad :: Int -> a -> [a] -> [a]
pad n v xs = xs ++ take (n - length(xs)) (repeat v)

padLeft :: Int -> a -> [a] -> [a]
padLeft  n v xs = take (n - length(xs)) (repeat v) ++ xs

delIdx :: Int -> [a] -> [a]
delIdx i xs = case splitAt i xs of
  (prefix, x:suffix) -> prefix ++ suffix

replaceIdx :: Int -> a -> [a] -> [a]
replaceIdx i x xs = case splitAt i xs of
  (prefix, _:suffix) -> prefix ++ (x:suffix)

cmpIdx :: Ord a => Idx a -> Idx a -> Maybe (Idx a)
cmpIdx (Only x) (Only y) | x == y = Just (Only x)
                         | otherwise = Nothing
cmpIdx (Only x) Anything = Just (Only x)
cmpIdx Anything (Only y) = Just (Only y)
cmpIdx Anything Anything = Just Anything

cmpIdxs :: Ord a => [Idx a] -> [Idx a] -> Comparison [Idx a]
cmpIdxs [] ys = Match ys GT
cmpIdxs xs [] = Match xs LT
cmpIdxs (x:xs) (y:ys) =
  let curmatch = case (x,y) of
                   (Only x', Only y') -> case compare x' y' of
                                            LT -> LeftSmall
                                            GT -> RightSmall
                                            EQ -> Match (Only x') EQ
                   (Only x' , Anything) -> Match (Only x') LT
                   (Anything, Only y' ) -> Match (Only y') GT
                   (Anything, Anything) -> Match Anything EQ
  in case curmatch of
    LeftSmall  -> LeftSmall
    RightSmall -> RightSmall
    Match z order -> case cmpIdxs xs ys of
                       LeftSmall  -> LeftSmall
                       RightSmall -> RightSmall
                       Match zs order' -> Match (z:zs) $ mergeOrder order' order

mergeOrder :: Ordering -> Ordering -> Ordering
mergeOrder x y | x == EQ   = y
               | otherwise = x

instance (Show a) => Show (Idx a) where
  show (Only x) = show x
  show Anything = "*"

mapFst :: (a -> b) -> [(a, c)] -> [(b, c)]
mapFst f zs = [(f x, y) | (x, y) <- zs]

printTable :: (Show a, Show b) => Int -> Table a b -> String
printTable rank (Table rows) =
  let rowsWithRank = mapFst (pad rank Anything) rows
  in concat . P.map formatRow . rowsToStrings $ rowsWithRank

rowsToStrings :: (Show a, Show b) => [([a], b)] -> [[String]]
rowsToStrings rows =
  let stringRows = [[show k | k <- ks] ++ [show v] | (ks,v) <- rows]
      evalMaxLen = foldr (\s w -> max (length s) w) 0
      ws = P.map evalMaxLen . transpose $ stringRows
      padRow xs = [padLeft w ' ' x | (w, x) <- zip ws xs]
  in P.map padRow stringRows

formatRow :: [String] -> String
formatRow rows = " " ++ concat (intersperse " | " rows) ++ "\n"
