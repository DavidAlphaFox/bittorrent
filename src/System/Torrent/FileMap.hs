{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE ViewPatterns     #-}
{-# OPTIONS -fno-warn-orphans #-}
module System.Torrent.FileMap
       ( FileMap

         -- * Construction
       , Mode (..)
       , def
       , mmapFiles
       , unmapFiles

         -- * Query
       , System.Torrent.FileMap.size

         -- * Modification
       , readBytes
       , writeBytes
       , unsafeReadBytes

         -- * Unsafe conversions
       , fromLazyByteString
       , toLazyByteString
       ) where

import Control.Applicative
import Control.Monad as L
import Data.ByteString as BS
import Data.ByteString.Internal as BS
import Data.ByteString.Lazy as BL
import Data.ByteString.Lazy.Internal as BL
import Data.Default
import Data.Vector as V -- TODO use unboxed vector
import Foreign
import System.IO.MMap

import Data.Torrent

-- 文件MAP表，位置和大小
-- 分片下载   
-- UNPACK会让编译器生成非打包的数据对齐
data FileEntry = FileEntry
  { filePosition :: {-# UNPACK #-} !FileOffset
  , fileBytes    :: {-# UNPACK #-} !BS.ByteString
  } deriving (Show, Eq)
-- FileMap是FileEntry的数组
type FileMap = Vector FileEntry
-- Mode的默认值
instance Default Mode where
  def = ReadWriteEx
-- 使用MMAP来提高性能
mmapFiles :: Mode -> FileLayout FileSize -> IO FileMap
mmapFiles mode layout = V.fromList <$> L.mapM mkEntry (accumPositions layout)
  where
    -- 路径，位置和期望的大小
    mkEntry (path, (pos, expectedSize)) = do
      -- 得到希望的的文件大小
      let esize = fromIntegral expectedSize -- FIXME does this safe?
      -- foreign pointer to beginning of raw region, 
      -- offset to your data and size of your data 
      (fptr, moff, msize) <- mmapFileForeignPtr path mode $ Just (0, esize)
      -- 如果文件大小不同，就报告失败
      if msize /= esize
        then error "mmapFiles" -- TODO unmap mapped files on exception
        else return $ FileEntry pos (PS fptr moff msize)

unmapFiles :: FileMap -> IO ()
unmapFiles = V.mapM_ unmapEntry
  where
    -- 进行内存释放，关闭MMAP句柄
    unmapEntry (FileEntry _ (PS fptr _ _)) = finalizeForeignPtr fptr

fromLazyByteString :: BL.ByteString -> FileMap
fromLazyByteString lbs = V.unfoldr f (0, lbs)
  where
    f (_,   Empty     ) = Nothing
    f (pos, Chunk x xs) = Just (FileEntry pos x, ((pos + chunkSize), xs))
      where chunkSize = fromIntegral $ BS.length x

-- | /O(n)/.
toLazyByteString :: FileMap -> BL.ByteString
toLazyByteString = V.foldr f Empty
  where
    f FileEntry {..} bs = Chunk fileBytes bs

-- | /O(1)/.
size :: FileMap -> FileOffset
size m
  |           V.null m               = 0
  | FileEntry {..} <- V.unsafeLast m
  = filePosition + fromIntegral (BS.length fileBytes)
-- 从FileMap中找出相应的文件偏移
bsearch :: FileOffset -> FileMap -> Maybe Int
bsearch x m
  | V.null m  = Nothing
  | otherwise = branch (V.length m `div` 2)
  where
    -- 二分搜索
    -- 此处使用的是ViewPatterns 语法
    -- c 绑定的是 整数，后面的是ViewPatterns
    branch c @ ((m !) -> FileEntry {..})
      -- 请求的偏移，小于文件的位置
      | x <  filePosition            = bsearch x (V.take c m)
      -- 请求的偏移，大于文件的位置
      | x > filePosition + fileSize = do
          Just ix <- bsearch x (V.drop (succ c) m)
          Just (succ c + ix)
      -- 余下的情况，表示请求的偏移，正好在filePosition + fileSize范围内
      | otherwise           = Just c
      where
        fileSize = fromIntegral (BS.length fileBytes)

-- | /O(log n)/.
drop :: FileOffset -> FileMap -> (FileSize, FileMap)
drop off m
  | Just ix <- bsearch off m
  , FileEntry {..} <- m ! ix = (off - filePosition, V.drop ix m)
  |         otherwise        = (0                 , V.empty)

-- | /O(log n)/.
take :: FileSize -> FileMap -> (FileMap, FileSize)
take len m
  |           len >= s       = (m                 , 0)
  | Just ix <- bsearch (pred len) m = let m' = V.take (succ ix) m
                               in (m', System.Torrent.FileMap.size m' - len)
  |          otherwise       = (V.empty           , 0)
  where
    s =  System.Torrent.FileMap.size m

-- | /O(log n + m)/. Do not use this function with 'unmapFiles'.
unsafeReadBytes :: FileOffset -> FileSize -> FileMap -> BL.ByteString
unsafeReadBytes off s m
  | (l  , m') <- System.Torrent.FileMap.drop off     m
  , (m'', _ ) <- System.Torrent.FileMap.take (off + s) m'
  = BL.take (fromIntegral s) $ BL.drop (fromIntegral l) $ toLazyByteString m''

readBytes :: FileOffset -> FileSize -> FileMap -> IO BL.ByteString
readBytes off s m = do
    let bs_copy = BL.copy $ unsafeReadBytes off s m
    forceLBS bs_copy
    return bs_copy
  where
    forceLBS  Empty      = return ()
    forceLBS (Chunk _ x) = forceLBS x

bscpy :: BL.ByteString -> BL.ByteString -> IO ()
bscpy (PS _ _ 0 `Chunk` dest_rest) src                         = bscpy dest_rest src
bscpy dest                         (PS _ _ 0 `Chunk` src_rest) = bscpy dest      src_rest
bscpy (PS dest_fptr dest_off dest_size `Chunk` dest_rest)
      (PS src_fptr  src_off  src_size  `Chunk` src_rest)
  = do let csize = min dest_size src_size
       withForeignPtr dest_fptr $ \dest_ptr ->
         withForeignPtr src_fptr $ \src_ptr ->
           memcpy (dest_ptr `advancePtr` dest_off)
                  (src_ptr  `advancePtr` src_off)
                  (fromIntegral csize) -- TODO memmove?
       bscpy (PS dest_fptr (dest_off + csize) (dest_size - csize) `Chunk` dest_rest)
             (PS src_fptr  (src_off  + csize) (src_size  - csize) `Chunk` src_rest)
bscpy _ _ = return ()

writeBytes :: FileOffset -> BL.ByteString -> FileMap -> IO ()
writeBytes off lbs m = bscpy dest src
  where
    src  = BL.take (fromIntegral (BL.length dest)) lbs
    dest = unsafeReadBytes off (fromIntegral (BL.length lbs)) m
