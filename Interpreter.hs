module Interpreter (Expr (..), BinOpName (..), binOpIdx, evalClosed) where

import qualified Data.Map.Strict as Map
import Util
import qualified Table as T

data Expr = Lit Int
          | Var Int
          | Lam Expr
          | App Expr Expr
          | IdxComp Expr
          | Get Expr Int
              deriving (Show)

data Val = IntVal Depth (T.Table Int Int)
         | LamVal Env IEnv Expr
         | Builtin BuiltinName [Val]

data BinOpName = Add | Mul | Sub | Div  deriving (Show)

type IEnv = (Depth, [Int])
type Env = [Val]
type Depth = Int

eval :: Expr -> Env -> IEnv -> Val
eval (Lit c) _   (d, _) = (composeN d lift) $ IntVal 0 (T.fromScalar c)
eval (Var v) env ienv = env !! v
eval (Lam body) env ienv = LamVal env ienv body
eval (App fexpr arg) env ienv = let f = eval fexpr env ienv
                                    x = eval arg env ienv
                                in evalApp f x
eval (IdxComp body) env (d, idxs) = let ienv = (d+1, d:idxs)
                                        env' = map lift env
                                    in case eval body env' ienv of
                                        IntVal d t -> IntVal (d-1) t
eval (Get e i) env ienv = let (_, idxs) = ienv
                              i' = idxs!!i
                          in case eval e env ienv of
                              IntVal d t -> IntVal d (T.diag i' d t)

lift :: Val -> Val
lift (IntVal d t) = IntVal (d+1) (T.insert d t)
lift (LamVal env (d,idxs) body) = LamVal (map lift env) (d+1, idxs) body
lift (Builtin name args) = Builtin name (map lift args)

data BuiltinName = BinOp BinOpName
                 | Iota
                 | Reduce deriving (Show)

numArgs :: BuiltinName -> Int
numArgs (BinOp _) = 2
numArgs Iota      = 1
numArgs Reduce    = 3

evalApp :: Val -> Val -> Val
evalApp (LamVal env ienv body) x = eval body (x:env) ienv
evalApp (Builtin name vs) x = let args = x:vs
                              in if length args < numArgs name
                                   then Builtin name args
                                   else evalBuiltin name (reverse args)

evalBuiltin :: BuiltinName -> [Val] -> Val
evalBuiltin (BinOp b) [IntVal d t1 , IntVal d' t2] | d == d' =
    let f x y = T.fromScalar $ binOpFun b (T.toScalar x) (T.toScalar y)
    in IntVal d (T.mapD2 d f t1 t2)
evalBuiltin Iota [IntVal d t] = IntVal d (T.mapD d T.iota t)


-- evalBuiltin Reduce (f : IntVal z d : IntVal t d' : []) | d == d' = undefined
    -- let f' x y = case evalApp (evalApp f (IntVal x d)) (IntVal y d)
    --              of IntVal t d -> t
    -- in IntVal (T.reduce d f' z t) d

binOpFun :: BinOpName -> Int -> Int -> Int
binOpFun Add = (+)
binOpFun Mul = (*)
binOpFun Sub = (-)

builtinEnv = [ Builtin Iota []
             , Builtin Reduce []
             , Builtin (BinOp Add) []
             , Builtin (BinOp Mul) []
             , Builtin (BinOp Sub) []
             , Builtin (BinOp Div) [] ]

binOpIdx :: BinOpName -> Int
binOpIdx b = case b of Add -> 0 ; Mul -> 1;
                       Sub -> 2 ; Div -> 3

evalClosed :: Expr -> Val
evalClosed e = eval e builtinEnv (0, [])

instance Show Val where
  show (IntVal _ t) = T.printTable t
  show (LamVal _ _ _) = "<lambda>"
  show (Builtin _ _ ) = "<builtin>"
