{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE NamedFieldPuns #-}
module Asm
  ( hsToWasm
  , Ins(..)
  , WasmType(Ref)  -- Re-export from WasmOp.
  , hsToIns
  , hsToGMachine
  , enc32
  ) where

import Control.Arrow
#ifdef __HASTE__
import "mtl" Control.Monad.State
#else
import Control.Monad.State
import Data.ByteString.Short (ShortByteString, unpack)
import qualified Data.ByteString.Short as SBS
import Data.Semigroup
#endif
import qualified Data.Bimap as BM
import Data.Char
import Data.Int
import Data.List
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe

import Boost
import DHC
import Std
import WasmOp

#ifdef __HASTE__
sbslen :: String -> Int
sbslen = length
unpack :: String -> [Int]
unpack = fmap ord
type ShortByteString = String
#else
sbslen :: ShortByteString -> Int
sbslen = SBS.length
#endif

-- | G-Machine instructions.
data Ins = Copro Int Int | PushInt Int64 | Push Int | PushGlobal String
  | PushRef Int32
  | PushString ShortByteString
  | MkAp | Slide Int | Split Int | Eval
  | UpdatePop Int | UpdateInd Int | Alloc Int
  | Casejump [(Maybe Int, [Ins])] | Trap
  | PushCallIndirect [Type]
  deriving Show

nPages :: Int
nPages = 8

encWasmOp :: WasmOp -> [Int]
encWasmOp op = case op of
  Get_local n -> 0x20 : leb128 n
  Set_local n -> 0x21 : leb128 n
  Tee_local n -> 0x22 : leb128 n
  Get_global n -> 0x23 : leb128 n
  Set_global n -> 0x24 : leb128 n
  I64_const n -> 0x42 : sleb128 n
  I32_const n -> 0x41 : sleb128 n
  Call n -> 0x10 : leb128 n
  Call_indirect n -> 0x11 : leb128 n ++ [0]
  I64_load m n -> [0x29, m, n]
  I64_store m n -> [0x37, m, n]
  I32_load m n -> [0x28, m, n]
  I32_load8_u m n -> [0x2d, m, n]
  I32_load16_u m n -> [0x2f, m, n]
  I32_store m n -> [0x36, m, n]
  I32_store8 m n -> [0x3a, m, n]
  Br n -> 0xc : leb128 n
  Br_if n -> 0xd : leb128 n
  Br_table bs a -> 0xe : leb128 (length bs) ++ concatMap leb128 (bs ++ [a])
  If _ as -> [0x4, 0x40] ++ concatMap encWasmOp as ++ [0xb]
  Block _ as -> [2, 0x40] ++ concatMap encWasmOp as ++ [0xb]
  Loop _ as -> [3, 0x40] ++ concatMap encWasmOp as ++ [0xb]
  _ -> maybe (error $ "unsupported: " ++ show op) pure $ lookup op rZeroOps

data WasmMeta = WasmMeta
  -- Arity of each user-defined function, whether exported or not.
  -- Eval uses this to remove the spine correctly.
  { arities :: Map String Int
  , exports :: [(String, [Type])]  -- List of public functions.
  , elements :: [(String, [Type])]
  , callTypes :: [[Type]]  -- Types needed by call_indirect ops.
  , strEndHP :: Int  -- Heap address immediately past the string constants.
  , strAddrs :: Map ShortByteString Int  -- String constant addresses.
  , storeTypes :: [Type]  -- Global store types.
  , callEncoders :: [(String, (Ins -> [WasmOp]) -> (QuasiWasm -> [WasmOp]) -> [WasmOp])]  -- Helpers for call_indirect that encode messages.
  }

hsToGMachine :: Boost -> String -> Either String (Map String Int, [(String, [Ins])])
hsToGMachine boost hs = first arities <$> hsToIns boost hs

hsToWasm :: Boost -> String -> Either String [Int]
hsToWasm boost s = insToBin s b . astToIns <$> hsToAst b qq s where
  b = stdBoost <> boost
  qq "here" h = Right h
  qq "wasm" prog = case hsToWasm boost prog of
    Left err -> Left err
    Right ints -> Right $ chr <$> ints
  qq _ _ = Left "bad scheme"

hsToIns :: Boost -> String -> Either String (WasmMeta, [(String, [Ins])])
hsToIns boost s = astToIns <$> hsToAst (stdBoost <> boost) qq s where
  qq "here" h = Right h
  qq _ _ = Left "bad scheme"

data CompilerState = CompilerState
  -- Bindings are local. They start empty and finish empty.
  -- During compilation, they hold the stack position of the bound variables.
  { bindings :: [(String, Int)]
  -- Each call_indirect indexes into the type section of the binary.
  -- We record the types used by the binary so we can collect and look them
  -- up when generating assembly.
  -- TODO: It'd be better to fold over CompilerState during compile to
  -- incrementally update these fields.
  , callIndirectTypes :: [[Type]]
  , stringConstants :: [ShortByteString]
  -- Compilation may generate auxiliary helpers.
  , helpers :: [(String, (Ins -> [WasmOp]) -> (QuasiWasm -> [WasmOp]) -> [WasmOp])]
  }

align4 :: Int -> Int
align4 n = (n + 3) `div` 4 * 4

mkStrConsts :: [ShortByteString] -> (Int, Map ShortByteString Int)
mkStrConsts ss = f (0, []) ss where
  f (p, ds) [] = (p, M.fromList ds)
  f (k, ds) (s:rest) = f (k + 16 + align4 (sbslen s), ((s, k):ds)) rest

astToIns :: Clay -> (WasmMeta, [(String, [Ins])])
astToIns cl = (WasmMeta
  { arities = funs
  , exports = listifyTypes <$> publics cl
  , elements = listifyTypes <$> secrets cl
  , callTypes = ciTypes
  , strEndHP = hp1
  , strAddrs = addrs
  , storeTypes = snd <$> stores cl
  , callEncoders = helps
  }, ins) where
  compilerOut = second (compile $ fst <$> stores cl) <$> supers cl
  ciTypes = foldl' union [] $ callIndirectTypes . snd . snd <$> compilerOut
  helps = concat $ helpers . snd . snd <$> compilerOut
  ins = second fst <$> compilerOut
  (hp1, addrs) = mkStrConsts $ nub $ concat $ stringConstants . snd . snd <$> compilerOut
  listifyTypes w = (w, inTypes [] $ fst $ fromJust $ lookup w $ funTypes cl)
  inTypes acc t = case t of
    a :-> b -> case toPrimeaType a of
      Just _ -> inTypes (a : acc) b
      _ -> error $ "unpublishable argument type: " ++ show t
    TApp (TC "IO") (TC "()") -> reverse acc
    _ -> error $ "exported functions must return IO ()"
  funs = M.fromList $ ((\(name, Ast (Lam as _)) -> (name, length as)) <$> supers cl)
    ++ (concatMap (\n -> [("#set-" ++ show n, 1), ("#get-" ++ show n, 0)]) [0..length (stores cl) - 1])

enc32 :: Int -> [Int]
enc32 n = (`mod` 256) . (div n) . (256^) <$> [(0 :: Int)..3]

toPrimeaType :: Type -> Maybe WasmType
toPrimeaType t = case t of
  TC "Int" -> Just I64
  TC "I32" -> Just I32
  TC "String" -> Just $ Ref "Databuf"
  TC s -> if elem s ["Port", "Databuf", "Actor", "Module"]
    then Just $ Ref s else Nothing
  _ -> Nothing

encMartinType :: WasmType -> Int
encMartinType t = case t of
  I32 -> 0x7f
  I64 -> 0x7e
  F32 -> 0x7d
  F64 -> 0x7c
  Ref "Actor" -> 0x6f
  Ref "Module" -> 0x6e
  Ref "Port" -> 0x6d
  Ref "Databuf" -> 0x6c
  Ref "Elem" -> 0x6b
  _ -> error "bad type"

fromStoreType :: Type -> WasmType
fromStoreType t = case t of
  TApp (TC "()") _ -> Ref "Elem"
  TApp (TC "[]") _ -> Ref "Elem"
  _ -> fromMaybe (error $ "bad persist: " ++ show t) $ toPrimeaType t

insToBin :: String -> Boost -> (WasmMeta, [(String, [Ins])]) -> [Int]
insToBin src (Boost imps _ boostPrims boostFuns) (wm@WasmMeta {exports, elements, strAddrs, storeTypes}, gmachine) = wasm where
  ees = exports ++ elements
  encMartinTypes :: [Type] -> [Int]
  encMartinTypes ts = 0x60 : lenc (encMartinType . fromJust . toPrimeaType <$> ts) ++ [0]
  encMartinTM :: String -> Int -> [Int]
  encMartinTM f t = leb128 (wasmFunNo ('@':f) - length imps) ++ leb128 t
  encMartinGlobal t i = [3] ++ leb128 (mainCalled + i) ++ leb128 t
  wasm = concat
    [ [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]  -- Magic string, version.

    -- Custom sections for Martin's Primea.
    , sectCustom "types" $ encMartinTypes . snd <$> ees
    , sectCustom "typeMap" $ zipWith encMartinTM (fst <$> ees) [0..]
    , sectCustom "persist" $ zipWith encMartinGlobal (encMartinType . fromStoreType <$> TC "I32":storeTypes) [0..]

    , sect 1 $ uncurry encSig . snd <$> BM.assocs typeMap  -- Type section.
    , sect 2 $ importFun <$> imps  -- Import section.
    , sect 3 $ pure . fst . fst . snd <$> wasmFuns  -- Function section.
    , sect 4 [[encType AnyFunc, 0] ++ leb128 256]  -- Table section (0 = no-maximum).
    , sect 5 [0 : leb128 nPages]  -- Memory section (0 = no-maximum).
    , sect 6 $  -- Global section (1 = mutable).
      [ [encType I32, 1, 0x41] ++ sleb128 memTop ++ [0xb]  -- SP
      , [encType I32, 1, 0x41] ++ sleb128 (strEndHP wm) ++ [0xb]  -- HP
      , [encType I32, 1, 0x41, 0, 0xb]  -- BP
      ]
      -- Global stores.
      -- First one records if `main` has been run yet.
      ++ map declareGlobal (TC "I32":storeTypes)
    , sect 7 $  -- Export section.
      -- The "public" functions are exported verbatim.
      [exportFun s ('@':s) | (s, _) <- exports] ++
      [ encStr "memory" ++ [2, 0]  -- 2 = external_kind Memory, 0 = memory index.
      , encStr "table" ++ [1, 0]  -- 1 = external_kind Table, 0 = memory index.
      ]
    , if null ees then [] else sect 9 [  -- Element section.
      [ 0  -- Table 0 (only one in MVP).
      -- Put public and secret functions at `slotMagic`.
      -- We assume these will never be overwritten!
      , 0x41, slotMagic, 0xb]
      ++ leb128 (length ees)
      ++ concatMap (leb128 . wasmFunNo . ('@':) . fst) ees]
    , sect 10 $ encProcedure . snd <$> wasmFuns  -- Code section.
    , sect 11 $ encStrConsts <$> M.assocs strAddrs  -- Data section.
    , sectCustom "dfndbg" [ord <$> show (sort $ swp <$> (M.assocs $ wasmFunMap))]
    , sectCustom "dfnhs" [ord <$> src]
    ]
  declareGlobal (TC "Int") = [encType I64, 1, 0x42, 0, 0xb]
  declareGlobal _ = [encType I32, 1, 0x41, 0, 0xb]
  swp (a, b) = (b, a)
  memTop = 65536*nPages - 4
  encStrConsts (s, offset) = concat
    [ [0, 0x41] ++ sleb128 offset ++ [0xb]
    , leb128 $ 16 + sbslen s
    , [fromEnum TagString, 0, 0, 0]
    , enc32 $ offset + 16
    , enc32 0
    , enc32 $ sbslen s
    , fromIntegral <$> unpack s
    ]
  -- 0 = external_kind Function.
  importFun ((m, f), ty) = encStr m ++ encStr f ++ [0, uncurry typeNo ty]
  typeNo ins outs = typeMap BM.!> (ins, outs)
  typeMap = BM.fromList $ zip [0..] $ nub $
    (snd <$> imps) ++  -- Types of imports
    -- Types of public and secret functions.
    (flip (,) [] . map toWasmType . snd <$> ees) ++
    -- call_indirect types.
    (flip (,) [] <$> map toWasmType <$> callTypes wm) ++
    (fst . snd <$> internalFuns)  -- Types of internal functions.
  exportFun name internalName = encStr name ++ (0 : leb128 (wasmFunNo internalName))
  -- Returns arity and 0-indexed number of given global function.
  getGlobal s = case M.lookup s $ M.insert "main" 0 $ arities wm of
    Just arity -> (arity, wasmFunNo s - firstPrim)
    Nothing -> (arityFromType $ fromMaybe (error $ "BUG! bad global: " ++ s) $ M.lookup s primsType, wasmFunNo s - firstPrim)
  firstPrim = wasmFunNo $ fst $ head evalFuns
  internalFuns =
    [ ("#eval", (([], []), evalAsm))
    , ("#mkap", (([], []), mkApAsm))
    , ("#pushint", (([I64], []), pushIntAsm))
    , ("#pushref", (([I32], []), pushRefAsm))
    , ("#push", (([I32], []), pushAsm))
    , ("#pushglobal", (([I32, I32], []), pushGlobalAsm))
    , ("#updatepop", (([I32], []), updatePopAsm))
    , ("#updateind", (([I32], []), updateIndAsm))
    , ("#alloc", (([I32], []), allocAsm))
    , ("#pairwith42", (([I32], []), pairWith42Asm))
    , ("#nil42", (([], []), nil42Asm))
    ] ++ (second (second $ concatMap deQuasi) <$> boostFuns)
  wasmFuns :: [(String, ((Int, Int), [WasmOp]))]
  wasmFuns =
    (second (first (\(ins, outs) -> (typeNo ins outs, 0))) <$> internalFuns)
    ++ evalFuns
    -- Wrappers for functions in "public" and "secret" section.
    ++ (wrap <$> ees)
  evalFuns =  -- Functions that "#eval" can call.
    -- Primitive functions.
    -- The assembly for "#eval" requires that the primitive functions
    -- directly precede those defined in the program.
    ((\(s, p) -> (s, ((typeNo [] [], 0), p))) <$> prims)
    -- Global get and set functions that interact with the DHC stack.
    ++ concat (zipWith mkStoreAsm storeTypes [0..])
    -- Functions from the program, except `main`.
    ++ (fromGMachine <$> filter (("main" /=) . fst) gmachine)
    -- The `main` function. Any supplied `main` function is appended to
    -- some standard setup code.
    ++ [("main", ((typeNo [] [], 0), preMainAsm ++ concatMap fromIns (fromMaybe [] $ lookup "main" gmachine) ++ [End]))]
    -- Wrappers for call_indirect calls.
    ++ (second (\f -> ((typeNo [] [], 0), f fromIns deQuasi)) <$> callEncoders wm)

  fromGMachine (f, g) = (f, ((typeNo [] [], 0), (++ [End]) $ concatMap fromIns g))
  preMainAsm =
    [ I32_const 1  -- mainCalled = 1
    , Set_global mainCalled
    ]
  wasmFunMap = M.fromList $ zip (((\(m, f) -> m ++ "." ++ f) . fst <$> imps) ++ (fst <$> wasmFuns)) [0..]
  wasmFunNo s = fromMaybe (error s) $ M.lookup s wasmFunMap

  wrap (f, ins) = (,) ('@':f) $ (,) (typeNo (toWasmType <$> ins) [], 0) $
    -- Wraps a DHC function.
    -- When a wasm function f(arg0, arg1, ...) is called,
    -- the arguments are placed in local variables.
    -- This wrapper builds:
    --
    --   f :@ arg0 :@ arg 1 :@ ... :@ #RealWorld
    --
    -- on the heap, places a pointer to his on the stack, then calls Eval.
    --
    -- Additionally, for each non-`main` function, first call `main`
    -- if a certain global flag is false.
    -- The `main` function always exists and sets this global flag.
    (if f /= "main" then
    [ Get_global mainCalled  -- if (!mainCalled) mainCalled = 1, main;
    , I32_eqz
    , If Nada (
      [ I32_const $ fromIntegral memTop  -- sp = top of memory
      , Set_global sp
      , Get_global sp  -- [sp] = 42
      , I32_const 42
      , I32_store 2 0
      , Get_global sp  -- sp = sp - 4
      , I32_const 4
      , I32_sub
      , Set_global sp
      ] ++ concatMap fromIns [PushGlobal "main", MkAp, Eval])
    ]
    else []) ++

    [ I32_const $ fromIntegral memTop  -- sp = top of memory
    , Set_global sp
    , Get_global sp  -- [sp] = 42
    , I32_const 42
    , I32_store 2 0
    , Get_global sp  -- sp = sp - 4
    , I32_const 4
    , I32_sub
    , Set_global sp
    ] ++
    -- Input arguments are local variables.
    -- We move these to our stack in reverse order.
    concat (reverse $ zipWith publicIn ins [0..]) ++
    -- Build the spine.
    concatMap fromIns (PushGlobal f : replicate (length ins + 1) MkAp) ++
    [ Call $ wasmFunNo "#eval"
    , End
    ]
  publicIn (TC "Int") i =
    [ Get_local i
    , Call $ wasmFunNo "#pushint"
    ]
  publicIn (TC "String") i =
    [ Get_global hp  -- [hp] = TagString
    , tag_const TagString
    , I32_store 2 0
    , Get_global hp  -- [hp + 4] = hp + 16
    , I32_const 4
    , I32_add
    , Get_global hp
    , I32_const 16
    , I32_add
    , I32_store 2 0
    , Get_global hp  -- [hp + 8] = 0
    , I32_const 8
    , I32_add
    , I32_const 0
    , I32_store 2 0
    , Get_global hp  -- [hp + 12] = bp = data.length local_i
    , I32_const 12
    , I32_add
    , Get_local i
    , Call $ wasmFunNo "data.length"
    , Set_global bp
    , Get_global bp
    , I32_store 2 0
    , Get_global hp  -- PUSH hp + 16
    , I32_const 16
    , I32_add
    , Get_global bp  -- PUSH bp
    , Get_local i  -- PUSH local_i
    , I32_const 0   -- PUSH 0
    , Call $ wasmFunNo "data.internalize"
    , Get_global sp  -- [sp] = hp
    , Get_global hp
    , I32_store 2 0
    , Get_global hp  -- hp = hp + bp + 16
    , Get_global bp
    , I32_add
    , I32_const 16
    , I32_add
    , Set_global hp
    , I32_const 0  -- Align hp.
    , Get_global hp
    , I32_sub
    , I32_const 3
    , I32_and
    , Get_global hp
    , I32_add
    , Set_global hp
    , Get_global sp  -- sp = sp - 4
    , I32_const 4
    , I32_sub
    , Set_global sp
    ]
  publicIn _ i =
    [ Get_local i
    , Call $ wasmFunNo "#pushref"
    ]
  sect t xs = t : lenc (varlen xs ++ concat xs)
  sectCustom s xs = 0 : lenc (encStr s ++ varlen xs ++ concat xs)
  encStr s = lenc $ ord <$> s
  encProcedure ((_, 0), body) = lenc $ 0:concatMap encWasmOp body
  encProcedure ((_, locCount), body) = lenc $ ([1, locCount, encType I32] ++) $ concatMap encWasmOp body
  encType I32 = 0x7f
  encType I64 = 0x7e
  encType (Ref _) = encType I32
  encType AnyFunc = 0x70
  encType _ = error "TODO"
  -- | Encodes function signature.
  encSig ins outs = 0x60 : lenc (encType <$> ins) ++ lenc (encType <$> outs)
  evalAsm =
    [ Block Nada
      [ Loop Nada
        [ Get_global sp  -- bp = [sp + 4]
        , I32_load 2 4
        , Set_global bp
        , Block Nada
          [ Block Nada
            [ Get_global bp
            , I32_load8_u 0 0
            , Br_table [0, 1, 3] 4  -- case [bp].8u; branch on Tag
            ]  -- 0: Ap
          , Get_global sp  -- [sp] = [bp + 8]
          , Get_global bp
          , I32_load 2 8
          , I32_store 2 0
          , Get_global sp  -- sp = sp - 4
          , I32_const 4
          , I32_sub
          , Set_global sp
          , Br 1
          ]  -- 1: Ind.
        , Get_global sp  -- [sp + 4] = [bp + 4]
        , Get_global bp
        , I32_load 2 4
        , I32_store 2 4
        , Br 0
        ]  -- 2: Eval loop.
      ]  -- 3: Global
    , Get_global bp  -- save bp, sp
    , Get_global sp
    , Get_global sp  -- bp = sp + 4 + 4 * ([bp].16u >> 8)
    , I32_const 4
    , I32_add
    , Get_global bp
    , I32_load16_u 1 0
    , I32_const 8
    , I32_shr_u
    , I32_const 4
    , I32_mul
    , I32_add
    , Set_global bp

    , Loop Nada  -- Remove spine.
      [ Get_global sp  -- sp = sp + 4
      , I32_const 4
      , I32_add
      , Set_global sp
      , Get_global sp  -- if sp /= bp then
      , Get_global bp
      , I32_ne
      , If Nada
        [ Get_global sp  -- [sp] = [[sp + 4] + 12]
        , Get_global sp
        , I32_load 2 4
        , I32_load 2 12
        , I32_store 2 0
        , Br 1
        ]  -- If
      ]  -- Loop
    , Set_global sp  -- restore bp, sp
    , Set_global bp
    ] ++ nest n ++ [End]
    where
      -- Eval functions are resolved in a giant `br_table`. This is ugly, but
      -- avoids run-time type-checking.
      n = length evalFuns
      nest 0 =
        [ Get_global bp  -- case [bp + 4]
        , I32_load 2 4
        , Br_table [0..n-1] n
        ]
      nest k = [Block Nada $ nest $ k - 1, Call $ firstPrim + k - 1, Return]

  mkStoreAsm t n =
    [ ("#set-" ++ show n, ((typeNo [] [], 0),
      [ I32_const 4  -- Push 0, Eval.
      , Call $ wasmFunNo "#push"
      , Call $ wasmFunNo "#eval"
      ] ++ (case t of
        TC "Int" ->
          [ Get_global sp  -- Set_global n [[sp + 4] + 8].64
          , I32_load 2 4
          , I64_load 3 8
          , Set_global $ storeOffset + n
          ]
        _ ->
          [ Get_global sp  -- Set_global n [[sp + 4] + 4]
          , I32_load 2 4
          , I32_load 2 4
          , Set_global $ storeOffset + n
          ]
      ) ++
      [ Get_global sp  -- sp = sp + 12
      , I32_const 12
      , I32_add
      , Set_global sp
      , Call $ wasmFunNo "#nil42"
      , End
      ]))
    , ("#get-" ++ show n, ((typeNo [] [], 0),
      [ Get_global hp  -- PUSH hp
      ] ++ (case t of
        TC "Int" ->
          [ Get_global hp  -- [hp] = TagInt
          , tag_const TagInt
          , I32_store 2 0
          , Get_global hp  -- [hp + 8] = Get_global n
          , Get_global $ storeOffset + n
          , I64_store 3 8
          , Get_global hp  -- hp = hp + 16
          , I32_const 16
          , I32_add
          , Set_global hp
          ]
        _ ->
          [ Get_global hp  -- [hp] = TagRef
          , tag_const TagRef
          , I32_store 2 0
          , Get_global hp  -- [hp + 4] = Get_global n
          , Get_global $ storeOffset + n
          , I32_store 2 4
          , Get_global hp  -- hp = hp + 8
          , I32_const 8
          , I32_add
          , Set_global hp
          ]
      ) ++
      [ Get_global sp  -- sp = sp + 4
      , I32_const 4
      , I32_add
      , Set_global sp
      , Call $ wasmFunNo "#pairwith42"
      , End
      ]))
    ]
  pairWith42Asm :: [WasmOp]
  pairWith42Asm =  -- [sp + 4] = (local0, #RealWorld)
    [ Get_global hp  -- [hp] = TagSum | (2 << 8)
    , I32_const $ fromIntegral $ fromEnum TagSum + 256 * 2
    , I32_store 2 0
    , Get_global hp  -- [hp + 4] = 0
    , I32_const 0
    , I32_store 2 4
    , Get_global hp  -- [hp + 8] = local0
    , Get_local 0
    , I32_store 2 8
    , Get_global hp  -- [hp + 12] = 42
    , I32_const 42
    , I32_store 2 12
    , Get_global sp  -- [sp + 4] = hp
    , Get_global hp
    , I32_store 2 4
    , Get_global hp  -- hp = hp + 16
    , I32_const 16
    , I32_add
    , Set_global hp
    , End
    ]
  -- | [sp + 4] = ((), #RealWorld)
  -- TODO: Optimize by placing this special value at a known location in memory.
  nil42Asm :: [WasmOp]
  nil42Asm =
    [ Get_global hp  -- [hp].64 = TagSum
    , I64_const $ fromIntegral $ fromEnum TagSum
    , I64_store 3 0
    , Get_global hp  -- PUSH hp
    , Get_global hp  -- hp = hp + 8
    , I32_const 8
    , I32_add
    , Set_global hp
    , Call $ wasmFunNo "#pairwith42"
    , End
    ]
  deQuasi :: QuasiWasm -> [WasmOp]
  deQuasi (Custom x) = case x of
    CallSym s -> [Call $ wasmFunNo s]
    ReduceArgs n -> concat $ replicate n $ concatMap fromIns [Push (n - 1), Eval]
    FarCall ts -> [Call_indirect $ typeNo (toWasmType <$> ts) []]

  deQuasi (Block t body) = [Block t $ concatMap deQuasi body]
  deQuasi (Loop  t body) = [Loop  t $ concatMap deQuasi body]
  deQuasi (If    t body) = [If    t $ concatMap deQuasi body]
  deQuasi (op) = [error "missing deQuasi case?" <$> op]

  prims = second (concatMap deQuasi . snd) <$> boostPrims
  primsType = M.fromList $ second fst <$> boostPrims

  fromIns :: Ins -> [WasmOp]
  fromIns instruction = case instruction of
    Trap -> [ Unreachable ]
    Eval -> [ Call $ wasmFunNo "#eval" ]  -- (Tail call.)
    PushInt n -> [ I64_const n, Call $ wasmFunNo "#pushint" ]
    PushRef n -> [ I32_const n, Call $ wasmFunNo "#pushref" ]
    Push n -> [ I32_const $ fromIntegral $ 4*(n + 1), Call $ wasmFunNo "#push" ]
    MkAp -> [ Call $ wasmFunNo "#mkap" ]
    PushGlobal fun | (n, g) <- getGlobal fun ->
      [ I32_const $ fromIntegral $ fromEnum TagGlobal + 256*n
      , I32_const $ fromIntegral g
      , Call $ wasmFunNo "#pushglobal"
      ]
    PushString s ->
      [ Get_global sp  -- [sp] = address of string const
      , I32_const $ fromIntegral $ strAddrs M.! s
      , I32_store 2 0
      , Get_global sp  -- sp = sp - 4
      , I32_const 4
      , I32_sub
      , Set_global sp
      ]
    PushCallIndirect ty ->
      -- 3 arguments: slot, argument tuple, #RealWorld.
      [ I32_const $ fromIntegral $ fromEnum TagGlobal + 256*3
      , I32_const $ fromIntegral $ wasmFunNo ('2':show ty) - firstPrim
      , Call $ wasmFunNo "#pushglobal"
      ]
    Slide 0 -> []
    Slide n ->
      [ Get_global sp  -- [sp + 4*(n + 1)] = [sp + 4]
      , Get_global sp
      , I32_load 2 4
      , I32_store 2 $ 4*(fromIntegral n + 1)
      , Get_global sp  -- sp = sp + 4*n
      , I32_const $ 4*fromIntegral n
      , I32_add
      , Set_global sp
      ]
    Alloc n -> [ I32_const $ fromIntegral n, Call $ wasmFunNo "#alloc" ]
    UpdateInd n ->
      [ I32_const $ fromIntegral $ 4*(n + 1), Call $ wasmFunNo "#updateind" ]
    UpdatePop n ->
      [ I32_const $ fromIntegral $ 4*(n + 1)
      , Call $ wasmFunNo "#updatepop"
      ]
    Copro m n ->
      [ Get_global hp  -- [hp] = TagSum | (n << 8)
      , I32_const $ fromIntegral $ fromEnum TagSum + 256 * n
      , I32_store 2 0
      , Get_global hp  -- [hp + 4] = m
      , I32_const $ fromIntegral m
      , I32_store 2 4
      ] ++ concat [
        [ Get_global hp  -- [hp + 4 + 4*i] = [sp + 4*i]
        , Get_global sp
        , I32_load 2 $ fromIntegral $ 4*i
        , I32_store 2 $ fromIntegral $ 4 + 4*i
        ] | i <- [1..n]] ++
      [ Get_global sp  -- sp = sp + 4*n
      , I32_const $ fromIntegral $ 4*n
      , I32_add
      , Set_global sp
      , Get_global sp  -- [sp] = hp
      , Get_global hp
      , I32_store 2 0
      , Get_global sp  -- sp = sp - 4
      , I32_const 4
      , I32_sub
      , Set_global sp
      , Get_global hp  -- hp = hp + 8 + ceil(n / 2) * 8
      , I32_const $ fromIntegral $ 8 + 8 * ((n + 1) `div` 2)
      , I32_add
      , Set_global hp
      ]
    Casejump alts0 -> let
      (underscore, unsortedAlts) = partition (isNothing . fst) alts0
      alts = sortOn fst unsortedAlts
      catchall = if null underscore then [Trap] else snd $ head underscore
      tab = zip (fromJust . fst <$> alts) [0..]
      m = maximum $ fromJust . fst <$> alts
      nest j (ins:rest) = pure $ Block Nada $ nest (j + 1) rest ++ concatMap fromIns ins ++ [Br j]
      nest _ [] = pure $ Block Nada
        [ Get_global bp  -- Br_table [bp + 4]
        , I32_load 2 4
        , Br_table [fromIntegral $ fromMaybe (length alts) $ lookup i tab | i <- [0..m]] $ m + 1
        ]
      in if null alts then concatMap fromIns catchall else
      -- [sp + 4] should be:
      -- 0: TagSum
      -- 4: "Enum"
      -- 8, 12, ...: fields
      [ Get_global sp  -- bp = [sp + 4]
      , I32_load 2 4
      , Set_global bp
      , Block Nada $ nest 1 (reverse $ snd <$> alts) ++ concatMap fromIns catchall
      ]

    Split 0 -> [Get_global sp, I32_const 4, I32_add, Set_global sp]
    Split n ->
      [ Get_global sp  -- bp = [sp + 4]
      , I32_load 2 4
      , Set_global bp
      , Get_global sp  -- sp = sp + 4
      , I32_const 4
      , I32_add
      , Set_global sp
      ] ++ concat [
        [ Get_global sp  -- [sp - 4*(n - i)] = [bp + 4 + 4*i]
        , I32_const $ fromIntegral $ 4*(n - i)
        , I32_sub
        , Get_global bp
        , I32_load 2 $ fromIntegral $ 4 + 4*i
        , I32_store 2 0
        ] | i <- [1..n]] ++
      [ Get_global sp  -- sp = sp - 4*n
      , I32_const $ fromIntegral $ 4*n
      , I32_sub
      , Set_global sp
      ]

leb128 :: Int -> [Int]
leb128 n | n < 128   = [n]
         | otherwise = 128 + (n `mod` 128) : leb128 (n `div` 128)

-- TODO: FIX!
sleb128 :: Integral a => a -> [Int]
sleb128 n | n < 64    = [fromIntegral n]
          | n < 128   = [128 + fromIntegral n, 0]
          | otherwise = 128 + (fromIntegral n `mod` 128) : sleb128 (n `div` 128)

varlen :: [a] -> [Int]
varlen xs = leb128 $ length xs

lenc :: [Int] -> [Int]
lenc xs = varlen xs ++ xs

sp, hp, bp, mainCalled, storeOffset :: Int
[sp, hp, bp, mainCalled, storeOffset] = [0, 1, 2, 3, 4]

compile :: [String] -> Ast -> ([Ins], CompilerState)
compile ps d = runState (mk1 ps d) $ CompilerState [] [] [] []

mk1 :: [String] -> Ast -> State CompilerState [Ins]
mk1 pglobals (Ast ast) = case ast of
  -- Thanks to lambda lifting, `Lam` can only occur at the top level.
  Lam as b -> do
    putBindings $ zip as [0..]
    (++ [UpdatePop $ length as, Eval]) <$> rec b
  I n -> pure [PushInt n]
  S s -> do
    st <- get
    put st { stringConstants = s:stringConstants st }
    pure [PushString s]
  t :@ u -> do
    mu <- rec u
    bump 1
    mt <- rec t
    bump (-1)
    pure $ case last mt of
      Copro _ _ -> mu ++ mt
      _ -> concat [mu, mt, [MkAp]]
  CallSlot ty encoders -> do
    st <- get
    put st { callIndirectTypes = callIndirectTypes st `union` [ty] }
    ms <- forM encoders rec
    addHelper ty ms
    pure [PushCallIndirect ty]
  Var v -> do
    m <- getBindings
    pure $ case lookup v m of
      Just k -> [Push k]
      _ | Just i <- elemIndex v pglobals ->
        -- Stores become (set n, get n) tuples.
        [ PushGlobal $ "#get-" ++ show i
        , PushGlobal $ "#set-" ++ show i
        , Copro 0 2
        ]
      _ -> [PushGlobal v]
  Pack n m -> pure [Copro n m]
  Cas expr alts -> do
    me <- rec expr
    xs <- forM alts $ \(p, body) -> do
      orig <- getBindings
      (f, b) <- case fromApList p of
        (Ast (Pack n _):vs) -> do
          bump $ length vs
          modifyBindings (zip (map (\(Ast (Var v)) -> v) vs) [0..] ++)
          bod <- rec body
          pure (Just $ fromIntegral n, Split (length vs) : bod ++ [Slide (length vs)])
        [Ast (Var s)] -> do
          bump 1
          modifyBindings ((s, 0):)
          (,) Nothing . (++ [Slide 1]) <$> rec body
        _ -> undefined
      putBindings orig
      pure (f, b)
    pure $ me ++ [Eval, Casejump xs]
  Let ds body -> let n = length ds in do
    orig <- getBindings
    bump n
    modifyBindings (zip (fst <$> ds) [n-1,n-2..0] ++)
    dsAsm <- mapM rec $ snd <$> ds
    b <- rec body
    putBindings orig
    pure $ Alloc n : concat (zipWith (++) dsAsm (pure . UpdateInd <$> [n-1,n-2..0])) ++ b ++ [Slide n]
  _ -> error $ "TODO: compile: " ++ show ast
  where
    bump n = modifyBindings $ fmap $ second (+n)
    modifyBindings f = putBindings =<< f <$> getBindings
    getBindings = bindings <$> get
    putBindings b = do
      st <- get
      put st { bindings = b }
    rec = mk1 pglobals

fromApList :: Ast -> [Ast]
fromApList (Ast (a :@ b)) = fromApList a ++ [b]
fromApList a = [a]

mkApAsm :: [WasmOp]
mkApAsm =
  [ Get_global hp  -- [hp] = TagAp
  , tag_const TagAp
  , I32_store 2 0
  , Get_global hp  -- [hp + 8] = [sp + 4]
  , Get_global sp
  , I32_load 2 4
  , I32_store 2 8
  , Get_global hp  -- [hp + 12] = [sp + 8]
  , Get_global sp
  , I32_load 2 8
  , I32_store 2 12
  , Get_global sp  -- [sp + 8] = hp
  , Get_global hp
  , I32_store 2 8
  , Get_global sp  -- sp = sp + 4
  , I32_const 4
  , I32_add
  , Set_global sp
  , Get_global hp  -- hp = hp + 16
  , I32_const 16
  , I32_add
  , Set_global hp
  , End
  ]
pushIntAsm :: [WasmOp]
pushIntAsm =
  [ Get_global sp  -- [sp] = hp
  , Get_global hp
  , I32_store 2 0
  , Get_global sp  -- sp = sp - 4
  , I32_const 4
  , I32_sub
  , Set_global sp
  , Get_global hp  -- [hp] = TagInt
  , tag_const TagInt
  , I32_store 2 0
  , Get_global hp  -- [hp + 8] = local_0
  , Get_local 0
  , I64_store 3 8
  , Get_global hp  -- hp = hp + 16
  , I32_const 16
  , I32_add
  , Set_global hp
  , End
  ]
pushRefAsm :: [WasmOp]
pushRefAsm =
  [ Get_global sp  -- [sp] = hp
  , Get_global hp
  , I32_store 2 0
  , Get_global sp  -- sp = sp - 4
  , I32_const 4
  , I32_sub
  , Set_global sp
  , Get_global hp  -- [hp] = TagRef
  , tag_const TagRef
  , I32_store 2 0
  , Get_global hp  -- [hp + 4] = local_0
  , Get_local 0
  , I32_store 2 4
  , Get_global hp  -- hp = hp + 8
  , I32_const 8
  , I32_add
  , Set_global hp
  , End
  ]
pushAsm :: [WasmOp]
pushAsm =
  [ Get_global sp  -- [sp] = [sp + local_0]
  , Get_global sp
  , Get_local 0  -- Should be 4*(n + 1).
  , I32_add
  , I32_load 2 0
  , I32_store 2 0
  , Get_global sp  -- sp = sp - 4
  , I32_const 4
  , I32_sub
  , Set_global sp
  , End
  ]
pushGlobalAsm :: [WasmOp]
pushGlobalAsm =
  [ Get_global sp  -- [sp] = hp
  , Get_global hp
  , I32_store 2 0
  , Get_global hp  -- [hp] = local_0 (should be TagGlobal | (n << 8))
  , Get_local 0
  , I32_store 2 0
  , Get_global hp  -- [hp + 4] = local_1 (should be local function index)
  , Get_local 1
  , I32_store 2 4
  , Get_global hp  -- hp = hp + 8
  , I32_const 8
  , I32_add
  , Set_global hp
  , Get_global sp  -- sp = sp - 4
  , I32_const 4
  , I32_sub
  , Set_global sp
  , End
  ]
updatePopAsm :: [WasmOp]
updatePopAsm =
  [ Get_global sp  -- bp = [sp + 4]
  , I32_load 2 4
  , Set_global bp
  , Get_global sp  -- sp = sp + local_0
  , Get_local 0  -- Should be 4*(n + 1).
  , I32_add
  , Set_global sp
  , Get_global sp  -- [[sp + 4]] = Ind
  , I32_load 2 4
  , tag_const TagInd
  , I32_store 2 0
  , Get_global sp  -- [[sp + 4] + 4] = bp
  , I32_load 2 4
  , Get_global bp
  , I32_store 2 4
  , End
  ]
allocAsm :: [WasmOp]
allocAsm =
  [ Loop Nada
    [ Get_local 0  -- Break when local0 == 0
    , I32_eqz
    , Br_if 1
    , Get_local 0  -- local0 = local0 - 1
    , I32_const 1
    , I32_sub
    , Set_local 0
    , Get_global sp  -- [sp] = hp
    , Get_global hp
    , I32_store 2 0
    , Get_global hp  -- [hp] = TagInd
    , tag_const TagInd
    , I32_store 2 0
    , Get_global hp  -- hp = hp + 8
    , I32_const 8
    , I32_add
    , Set_global hp
    , Get_global sp  -- sp = sp - 4
    , I32_const 4
    , I32_sub
    , Set_global sp
    , Br 0
    ]
  , End
  ]
updateIndAsm :: [WasmOp]
updateIndAsm =
  [ Get_global sp  -- sp = sp + 4
  , I32_const 4
  , I32_add
  , Set_global sp
  -- local0 should be 4*(n + 1)
  , Get_global sp  -- [[sp + local0] + 4] = [sp]
  , Get_local 0
  , I32_add
  , I32_load 2 0
  , Get_global sp
  , I32_load 2 0
  , I32_store 2 4
  , End
  ]

toWasmType :: Type -> WasmType
toWasmType (TC "Int") = I64
toWasmType _ = I32

addHelper :: [Type] -> [[Ins]] -> State CompilerState ()
addHelper ty ms = do
  st <- get
  put st { helpers = ('2':show ty, f):helpers st }
  where
  f fromIns deQuasi = case (ty, ms) of
    ([t], [encoder]) ->
      -- 3 arguments: slot, argument tuple, #RealWorld.
      -- When sending a message with only one item, we have a bare argument
      -- instead of an argument tuple
      -- Evaluate single argument.
      concatMap fromIns (Push 1:encoder ++ [MkAp, Eval]) ++
      pushCallIndirectArg t ++
      [ Get_global sp  -- sp = sp + 4
      , I32_const 4
      , I32_add
      , Set_global sp
      ] ++
      concatMap fromIns [ Push 0, Eval ] ++  -- Get slot.
      concatMap deQuasi
      [ Get_global sp  -- PUSH [[sp + 4] + 4]
      , I32_const 4
      , I32_add
      , I32_load 2 0
      , I32_const 4
      , I32_add
      , I32_load 2 0
      , Custom $ FarCall [t]
      , Get_global sp  -- sp = sp + 16
      , I32_const 16
      , I32_add
      , Set_global sp
      , Custom $ CallSym "#nil42"
      , End
      ]
    _ ->
      -- Evaluate argument tuple.
      concatMap fromIns [ Push 1, Eval ] ++
      concat [
        [ Get_global sp  -- sp = sp - 4
        , I32_const 4
        , I32_sub
        , Set_global sp
        , Get_global sp  -- [sp + 4] = [[sp + 8] + 4*(i + 2)]
        , I32_const 4
        , I32_add
        , Get_global sp
        , I32_const 8
        , I32_add
        , I32_load 2 0
        , I32_const $ fromIntegral $ 4*(i + 2)
        , I32_add
        , I32_load 2 0
        , I32_store 2 0
        ] ++
        concatMap fromIns ((ms!!i) ++ [MkAp, Eval]) ++
        pushCallIndirectArg t ++
        [ Get_global sp  -- sp = sp + 4
        , I32_const 4
        , I32_add
        , Set_global sp
        ] | (t, i) <- zip ty [0..]] ++
      [ Get_global sp  -- sp = sp + 4
      , I32_const 4
      , I32_add
      , Set_global sp
      ] ++
      concatMap fromIns [ Push 0, Eval ] ++  -- Get slot.
      concatMap deQuasi
      [ Get_global sp  -- PUSH [[sp + 4] + 4]
      , I32_const 4
      , I32_add
      , I32_load 2 0
      , I32_const 4
      , I32_add
      , I32_load 2 0
      , Custom $ FarCall ty
      , Get_global sp  -- sp = sp + 16
      , I32_const 16
      , I32_add
      , Set_global sp
      , Custom $ CallSym "#nil42"
      , End
      ]

pushCallIndirectArg :: Type -> [WasmOp]
pushCallIndirectArg t = case t of
  TC "Int" ->
    [ Get_global sp  -- PUSH [[sp + 4] + 8].64
    , I32_load 2 4
    , I64_load 3 8
    ]
  _ ->
    [ Get_global sp  -- PUSH [[sp + 4] + 4]
    , I32_load 2 4
    , I32_load 2 4
    ]
