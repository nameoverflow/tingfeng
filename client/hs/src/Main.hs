{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (forM_, when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Wasm.Prim (JSString (..), fromJSString, toJSString)
import System.IO.Unsafe (unsafePerformIO)
import Tingfeng.Catalog (parseActionCatalog)
import Tingfeng.Pose (parsePoseLibrary)
import Tingfeng.Protocol
  ( CreationChoice,
    decodeServerMsg,
    encodeLogin,
    encodeRequestCreationConfig,
  )
import Tingfeng.Render (buildFrameBatch)
import Tingfeng.State

-- Synchronous (unsafe) host imports so every state transition completes synchronously
foreign import javascript unsafe "performance.now()"
  js_nowMs :: IO Double

foreign import javascript unsafe "globalThis.__tfHost.submitFrame($1, $2, $3, $4, $5, $6, $7)"
  js_submitFrame :: JSString -> Int -> Double -> Double -> Double -> Double -> Double -> IO ()

foreign import javascript unsafe "globalThis.__tfHost.syncOverlay($1)"
  js_syncOverlay :: JSString -> IO ()

foreign import javascript unsafe "globalThis.__tfHost.syncLabState($1)"
  js_syncLabState :: JSString -> IO ()

foreign import javascript unsafe "globalThis.__tfHost.sendWs($1)"
  js_sendWs :: JSString -> IO ()

foreign import javascript unsafe "globalThis.__tfHost.connectWs($1, $2, $3)"
  js_connectWs :: JSString -> JSString -> JSString -> IO ()

foreign import javascript unsafe "globalThis.__tfHost.setCursor($1)"
  js_setCursor :: JSString -> IO ()

foreign import javascript unsafe "globalThis.__tfHost.playSfx($1)"
  js_playSfx :: JSString -> IO ()

foreign import javascript unsafe "globalThis.__tfHost.saveLocal($1, $2)"
  js_saveLocal :: JSString -> JSString -> IO ()

-- Exported Haskell Wasm entry points
foreign export javascript "hs_init_app"
  hsInitApp :: JSString -> JSString -> JSString -> JSString -> JSString -> JSString -> Double -> Double -> Int -> IO ()

foreign export javascript "hs_step_frame"
  hsStepFrame :: Double -> Double -> Double -> Int -> IO ()

foreign export javascript "hs_on_ws_open"
  hsOnWsOpen :: JSString -> JSString -> JSString -> IO ()

foreign export javascript "hs_on_ws_message"
  hsOnWsMessage :: JSString -> IO ()

foreign export javascript "hs_on_ws_close"
  hsOnWsClose :: IO ()

foreign export javascript "hs_set_hidden"
  hsSetHidden :: Int -> IO ()

foreign export javascript "hs_pointer_move"
  hsPointerMove :: Double -> Double -> IO ()

foreign export javascript "hs_pointer_click"
  hsPointerClick :: Double -> Double -> IO ()

foreign export javascript "hs_pan_zoom"
  hsPanZoom :: Double -> Double -> Double -> IO ()

foreign export javascript "hs_ui_action"
  hsUiAction :: JSString -> JSString -> JSString -> IO ()

foreign export javascript "hs_lab_cmd"
  hsLabCmd :: JSString -> JSString -> JSString -> JSString -> Double -> IO ()

{-# NOINLINE globalModelRef #-}
globalModelRef :: IORef (Maybe ClientModel)
globalModelRef = unsafePerformIO (newIORef Nothing)

{-# NOINLINE pendingCreationRef #-}
pendingCreationRef :: IORef (Maybe CreationChoice)
pendingCreationRef = unsafePerformIO (newIORef Nothing)

{-# NOINLINE activeWsModeRef #-}
activeWsModeRef :: IORef Text
activeWsModeRef = unsafePerformIO (newIORef "")

tFromJS :: JSString -> Text
tFromJS = T.pack . fromJSString

tToJS :: Text -> JSString
tToJS = toJSString . T.unpack

runCmds :: [ClientCmd] -> IO ()
runCmds = mapM_ $ \cmd -> case cmd of
  CmdSendWs payload -> js_sendWs (tToJS payload)
  CmdOpenConfigWs -> js_connectWs (tToJS "config_only") (tToJS "") (tToJS "")
  CmdConnectWs u p mChoice -> do
    writeIORef pendingCreationRef mChoice
    let modeStr = case mChoice of Nothing -> "login"; Just _ -> "create"
    js_connectWs (tToJS modeStr) (tToJS u) (tToJS p)
  CmdSetCursor cur -> js_setCursor (tToJS cur)
  CmdPlaySfx sfx -> js_playSfx (tToJS sfx)
  CmdSaveLocal k v -> js_saveLocal (tToJS k) (tToJS v)

flushState :: ClientModel -> IO ClientModel
flushState m = do
  js_syncLabState (tToJS (buildLabStateJson m))
  if cmUiDirty m
    then do
      js_syncOverlay (tToJS (buildOverlayJson m))
      pure (m {cmUiDirty = False})
    else pure m

hsInitApp :: JSString -> JSString -> JSString -> JSString -> JSString -> JSString -> Double -> Double -> Int -> IO ()
hsInitApp pageJS poseJS stgJS fistJS swordJS effJS w h redInt = do
  let page = case tFromJS pageJS of
        "lab" -> PageBattleLab
        "poses" -> PagePoseSheet
        _ -> PageGame
      poseLib = case parsePoseLibrary (tFromJS poseJS) of
        Right l -> l
        Left err -> error ("PoseLibrary error: " <> err)
      cat = case parseActionCatalog (tFromJS stgJS) [tFromJS fistJS, tFromJS swordJS, tFromJS effJS] of
        Right c -> c
        Left err -> error ("ActionCatalog error: " <> err)
      m0 = initClientModel page poseLib cat w h (redInt /= 0)
      (m1, cmds) =
        if page == PageBattleLab
          then handleLabCommand "seed" "female" "male" "" 0 m0
          else (m0, [])
  runCmds cmds
  m2 <- flushState m1
  writeIORef globalModelRef (Just m2)

hsStepFrame :: Double -> Double -> Double -> Int -> IO ()
hsStepFrame dtMs w h redInt = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 -> do
    t0 <- js_nowMs
    let mRed = m0 {cmReducedMotion = redInt /= 0}
        (m1, cmds) = stepClientFrame dtMs w h mRed
        (batchTxt, hitboxes, cmdCount) = buildFrameBatch m1
    t1 <- js_nowMs
    let elapsed = max 0.03 (t1 - t0)
        smoothMs = cmWasmStepMs m1 * 0.88 + elapsed * 0.12
        m2 = m1 {cmHitboxes = hitboxes, cmWasmStepMs = smoothMs, cmDrawCmdCount = cmdCount}
        modeInt = if cmRenderMode m2 == ModeWebGL2Ink then 1 else 0
        (su, sv) = cmShockPos m2
    js_submitFrame (tToJS batchTxt) modeInt su sv (cmShockAge m2) (cmShockPower m2) (cmClockMs m2 / 1000.0)
    runCmds cmds
    m3 <- flushState m2
    writeIORef globalModelRef (Just m3)

hsOnWsOpen :: JSString -> JSString -> JSString -> IO ()
hsOnWsOpen modeJS userJS passJS = do
  let mode = tFromJS modeJS
      u = T.strip (tFromJS userJS)
      p = tFromJS passJS
  writeIORef activeWsModeRef mode
  if mode == "config_only"
    then js_sendWs (tToJS encodeRequestCreationConfig)
    else do
      mChoice <- readIORef pendingCreationRef
      writeIORef pendingCreationRef Nothing
      js_sendWs (tToJS (encodeLogin u p mChoice))
      mm <- readIORef globalModelRef
      forM_ mm $ \m0 -> do
        let m1 = m0 {cmUsername = u, cmConnected = True, cmConnecting = False, cmRequestedInit = False, cmUiDirty = True}
        m2 <- flushState m1
        writeIORef globalModelRef (Just m2)

hsOnWsMessage :: JSString -> IO ()
hsOnWsMessage rawJS = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 ->
    case decodeServerMsg (tFromJS rawJS) of
      Left _ -> pure ()
      Right sm -> do
        let (m1, cmds) = applyServerMessage sm m0
        runCmds cmds
        m2 <- flushState m1
        writeIORef globalModelRef (Just m2)

hsOnWsClose :: IO ()
hsOnWsClose = do
  lastMode <- readIORef activeWsModeRef
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 ->
    when (lastMode /= "config_only" && cmRoomName m0 /= "竹间试招") $ do
      let m1 = m0 {cmConnected = False, cmConnecting = False, cmUiDirty = True}
      m2 <- flushState m1
      writeIORef globalModelRef (Just m2)

hsSetHidden :: Int -> IO ()
hsSetHidden hiddenInt = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 -> do
    let m1 = setDocumentHidden (hiddenInt /= 0) m0
    m2 <- flushState m1
    writeIORef globalModelRef (Just m2)

hsPointerMove :: Double -> Double -> IO ()
hsPointerMove x y = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 -> do
    let (m1, cmds) = handlePointerMove x y m0
    runCmds cmds
    writeIORef globalModelRef (Just m1)

hsPointerClick :: Double -> Double -> IO ()
hsPointerClick x y = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 -> do
    let (m1, cmds) = handlePointerClick x y m0
    runCmds cmds
    m2 <- flushState m1
    writeIORef globalModelRef (Just m2)

hsPanZoom :: Double -> Double -> Double -> IO ()
hsPanZoom dx dy zFactor = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 -> do
    let m1 = zoomCameraBy zFactor (panCameraBy dx dy m0)
    writeIORef globalModelRef (Just m1)

hsUiAction :: JSString -> JSString -> JSString -> IO ()
hsUiAction kindJS a1JS a2JS = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 -> do
    let (m1, cmds) = handleUiAction (tFromJS kindJS) (tFromJS a1JS) (tFromJS a2JS) m0
    runCmds cmds
    m2 <- flushState m1
    writeIORef globalModelRef (Just m2)

hsLabCmd :: JSString -> JSString -> JSString -> JSString -> Double -> IO ()
hsLabCmd cmdJS a1JS a2JS a3JS numArg = do
  mm <- readIORef globalModelRef
  forM_ mm $ \m0 -> do
    let (m1, cmds) = handleLabCommand (tFromJS cmdJS) (tFromJS a1JS) (tFromJS a2JS) (tFromJS a3JS) numArg m0
    runCmds cmds
    m2 <- flushState m1
    writeIORef globalModelRef (Just m2)

main :: IO ()
main = when False (pure ())
