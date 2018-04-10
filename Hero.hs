{-# LANGUAGE NamedFieldPuns #-}

module Hero (Wasm(dfnExports, haskell), HeroVM, parseWasm,
  runWasm, mkHeroVM, setArgsVM,
  setTable,
  globalVM, setGlobalVM,
  getNumVM, putNumVM,
  stateVM, putStateVM,
  CustomWasmOp(I32_const, I64_const), WasmOp) where

import Data.Bits
import Data.Char (ord)
import Data.Int
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.List
import Data.Maybe
import Data.Word

import Network.DFINITY.Parse

import WasmOp

data HeroVM a = HeroVM
  { globs :: IntMap WasmOp
  , locs  :: [IntMap WasmOp]
  , stack :: [WasmOp]
  , insts :: [[WasmOp]]
  , mem   :: IntMap Int
  , sigs  :: IntMap ([WasmType], [WasmType])
  , table :: IntMap (HeroVM a -> [WasmOp] -> IO (HeroVM a))
  , wasm  :: Wasm
  , state :: a
  }

stateVM :: HeroVM a -> a
stateVM vm = state vm

putStateVM :: a -> HeroVM a -> HeroVM a
putStateVM a vm = vm {state = a}

getNumVM :: Integral n => Int -> Int32 -> HeroVM a -> n
getNumVM w addr vm = getNum w addr $ mem vm

globalVM :: HeroVM a -> IntMap WasmOp
globalVM vm = globs vm

setGlobalVM :: [(Int, WasmOp)] -> HeroVM a -> HeroVM a
setGlobalVM m vm = vm { globs = IM.fromList m `IM.union` globs vm }

putNumVM :: Integral n => Int -> Int32 -> n -> HeroVM a -> HeroVM a
putNumVM w addr n vm@(HeroVM {mem}) = vm { mem = putNum w addr n mem }

getNum :: Integral n => Int -> Int32 -> IntMap Int -> n
--getNum w addr mem = sum $ zipWith (*) (fromIntegral <$> bs) ((256^) <$> [(0 :: Int)..]) where bs = fmap (mem IM.!) ((fromIntegral addr +) <$> [0..w-1])
getNum w addr mem = sum $ zipWith (*) (fromIntegral <$> bs) ((256^) <$> [(0 :: Int)..]) where bs = fmap (\a -> fromMaybe 0 $ IM.lookup a mem) ((fromIntegral addr +) <$> [0..w-1])

putNum :: Integral n => Int -> Int32 -> n -> IntMap Int -> IntMap Int
putNum w addr n mem = foldl' f mem [0..w-1] where
  f m k = IM.insert (fromIntegral addr + k) (getByte k) m
  getByte k = fromIntegral n `div` (256^k) `mod` 256

rem32U :: Int32 -> Int32 -> Int32
rem32U a b = fromIntegral $ mod ((fromIntegral a) :: Word32) $ fromIntegral (fromIntegral b :: Word32)

rotateL32 :: Word32 -> Word32 -> Int32
rotateL32 a b = fromIntegral $ rotateL a $ fromIntegral (b `mod` 32)

rotateR32 :: Word32 -> Word32 -> Int32
rotateR32 a b = fromIntegral $ rotateL a $ fromIntegral (b `mod` 32)

shiftL32 :: Word32 -> Word32 -> Int32
shiftL32 a b = fromIntegral $ shiftL a $ fromIntegral (b `mod` 32)

shiftR32U :: Word32 -> Word32 -> Int32
shiftR32U a b = fromIntegral $ shiftR a $ fromIntegral (b `mod` 32)

shiftR64U :: Int64 -> Int64 -> Int64
shiftR64U a b = fromIntegral $ shiftR ((fromIntegral a) :: Word64) $ fromIntegral ((fromIntegral b :: Word64) `mod` 64)

drop' :: Int -> [a] -> [a]
drop' n as | n > length as = error "BAD DROP"
           | otherwise = drop n as

take' :: Int -> [a] -> [a]
take' n as | n > length as = error "BAD TAKE"
           | otherwise = take n as

-- The `End` opcode is reintroduced at the ends of function calls, so we
-- know when to pop locals, and when to stop popping instructions for `Return`.
runWasm :: ((String, String) -> HeroVM a -> [WasmOp] -> IO (HeroVM a))
  -> [Char] -> HeroVM a -> IO ([WasmOp], HeroVM a)
runWasm fns s herovm = let
  Wasm {imports, exports, decls, code} = wasm herovm
  fCount = length imports
  run vm@HeroVM {insts, stack} | null insts = pure (stack, vm)
  run vm@HeroVM {insts} | null $ head insts = case tail insts of
    ((Loop _ _:rest):t) -> run vm {insts = rest:t}
    _                   -> run vm {insts = tail insts}
  run vm@HeroVM{globs, locs, stack, insts, mem} = case head $ head insts of
    Call_indirect k -> do
      let
        -- TODO: Dynamic type-check.
        inCount = length $ fst $ sigs vm IM.! k
        (I32_const i:args) = take' (inCount + 1) stack
      run =<< (table vm IM.! fromIntegral i) (step $ drop' (inCount + 1) stack) (reverse args)
    Call i -> if i < fCount then do
        let
          (importName, (ins, _)) = imports!!i
          k = length ins
        run =<< fns importName (step $ drop' k stack) (reverse $ take' k stack)
      else do
        let
          (locals, body) = code!!(i - fCount)
          k = length $ fst $ decls !! (i - fCount)
        run vm { stack = drop' k stack, locs = IM.fromList (zip [0..] $ reverse (take' k stack) ++ locals):locs, insts = body:(End:head i1):tail i1 }
    Return -> run vm { insts = dropWhile ((End /=) . head) insts }
    End -> run vm { locs = tail locs, insts = i1 }
    Set_local i -> run vm {locs = IM.insert i (head stack) (head locs):tail locs, stack = tail stack, insts = i1}
    Get_local i -> if i >= IM.size (head locs) then error $ "BUG! bad local: " ++ show(i, locs) else run $ step $ head locs IM.! i:stack
    Tee_local i -> run vm {locs = IM.insert i (head stack) (head locs):tail locs, insts = i1}
    Set_global i -> run vm {globs = IM.insert i (head stack) globs, stack = tail stack, insts = i1}
    Get_global i -> if i >= IM.size globs then error $ "BUG! bad global: " ++ show (i, globs)
      else run $ step $ globs IM.! i:stack
    c@(I32_const _) -> run $ step $ c:stack
    c@(I64_const _) -> run $ step $ c:stack
    I32_xor -> binOp32 xor
    I32_and -> binOp32 (.&.)
    I32_add -> binOp32 (+)
    I32_sub -> binOp32 (-)
    I32_mul -> binOp32 (*)
    I32_rem_u -> binOp32 rem32U
    I32_shl -> binOp32U shiftL32
    I32_rotl -> binOp32U rotateL32
    I32_rotr -> binOp32U rotateR32
    I32_shr_u -> binOp32U shiftR32U
    I32_lt_u -> binOp32U $ ((fromIntegral . fromEnum) .) . (<)
    I32_le_s -> binOp32 $ ((fromIntegral . fromEnum) .) . (<=)
    I32_ne -> binOp32 $ ((fromIntegral . fromEnum) .) . (/=)
    I32_eq -> binOp32 $ ((fromIntegral . fromEnum) .) . (==)
    I32_eqz -> let
      (I32_const a:t) = stack
      in run $ step $ (I32_const $ fromIntegral $ fromEnum $ a == 0):t
    I64_le_s -> boolBinOp64 (<=)
    I64_lt_s -> boolBinOp64 (<)
    I64_ge_s -> boolBinOp64 (>=)
    I64_gt_s -> boolBinOp64 (>)
    I64_eq -> boolBinOp64 (==)
    I64_add -> binOp64 (+)
    I64_sub -> binOp64 (-)
    I64_mul -> binOp64 (*)
    I64_shr_u -> binOp64 shiftR64U
    I64_extend_s_i32 -> let
      I32_const a = head stack
      c = I64_const $ fromIntegral a
      in run $ step (c:tail stack)
    I32_wrap_i64 -> let
      I64_const a = head stack
      c = I32_const $ fromIntegral a
      in run $ step (c:tail stack)
    I32_load8_u _ _ -> do
      let I32_const addr = head stack
          c = I32_const $ getNum 1 addr mem
      run $ step (c:tail stack)
    I32_load16_u _ _ -> do
      let I32_const addr = head stack
          c = I32_const $ getNum 2 addr mem
      run $ step (c:tail stack)
    I32_load _ _ -> do
      let I32_const addr = head stack
          c = I32_const $ getNum 4 addr mem
      run $ step (c:tail stack)
    I32_store _ _ -> let (I32_const n:I32_const addr:_) = stack in do
      let mem' = putNum 4 addr n mem
      run (step $ drop 2 stack) { mem = mem'}
    I32_store8 _ _ -> let (I32_const n:I32_const addr:_) = stack in do
      let mem' = putNum 1 addr n mem
      run (step $ drop 2 stack) { mem = mem'}
    I64_store _ _ -> do
      let
        I32_const addr = stack!!1
        I64_const n = head stack
      let mem' = putNum 8 addr n mem
      run (step $ drop 2 stack) { mem = mem'}
    I64_load _ _ -> do
      let I32_const addr = head stack
          c = I64_const $ getNum 8 addr mem
      run $ step (c:tail stack)
    If _ bl -> let I32_const n = head stack in if n /= 0
      then run vm {stack = tail stack, insts = bl:i1}
      else run vm {stack = tail stack, insts = i1}
    Block _ bl -> run vm {insts = bl:i1}
    Loop _ bl -> run vm {insts = bl:insts}
    Br k -> run vm {insts = drop (k + 1) insts}
    Br_if k -> let (I32_const n:t) = stack in if n /= 0
      then run vm {stack = t, insts = drop (k + 1) insts}
      else run vm {stack = t, insts = i1}
    Br_table as d -> do
      let
        n = fromIntegral n' where I32_const n' = head stack
        k = if n < 0 || n >= length as then d else as!!n
      run vm {stack = tail stack, insts = drop (k + 1) insts}
    Unreachable -> pure ([], herovm)
    _ -> error $ "TODO: " ++ show (head $ head insts)
    where
      step newStack = vmNext { stack = newStack }
      vmNext = vm { insts = i1 }
      i1 = tail (head insts):tail insts
      binOp32 f = run $ step (c:drop 2 stack) where
        (I32_const b:I32_const a:_) = stack
        c = I32_const $ f a b
      binOp32U f = run $ step (c:drop 2 stack) where
        (I32_const b:I32_const a:_) = stack
        c = I32_const $ f (toU32 a) (toU32 b) where
          toU32 n = (fromIntegral n :: Word32)
      binOp64 f = run $ step (c:drop 2 stack) where
        (I64_const b:I64_const a:_) = stack
        c = I64_const $ f a b
      boolBinOp64 f = run $ step (c:drop 2 stack) where
        (I64_const b:I64_const a:_) = stack
        c = I32_const $ fromIntegral $ fromEnum $ f a b
  fI = fromMaybe (error $ "no such export: " ++ s) $ lookup s exports
  in run herovm { insts = [[Call fI]] }

-- | Builds a HeroVM for given Wasm binary and persistent globals.
mkHeroVM :: a -> Wasm -> [(Int, WasmOp)] -> HeroVM a
mkHeroVM st w gs = HeroVM initGlobals [] [] [] (IM.fromList $
    concatMap strToAssocs $ dataSection w)
    (IM.fromList $ zip [0..] $ types w)
    IM.empty
    w
    st
  where
  initGlobals = IM.fromList $ (zip [0..] $ head . snd <$> globals w) ++ gs
  strToAssocs ([I32_const n], s) = zip [fromIntegral n..] $ ord <$> s
  strToAssocs _ = error "BUG!"

-- | Place arguments on WebAssembly stack.
setArgsVM :: [WasmOp] -> HeroVM a -> HeroVM a
setArgsVM ls vm = vm { stack = reverse ls ++ stack vm }

setTable :: Int32 -> (HeroVM a -> [WasmOp] -> IO (HeroVM a)) -> HeroVM a -> HeroVM a
setTable slot fun vm = vm { table = IM.insert (fromIntegral slot) fun $ table vm }
