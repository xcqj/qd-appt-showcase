/**
 * 视频转 GIF
 *
 * 为什么不用 ffmpeg 直接出 GIF：Playwright 自带的 ffmpeg 是**精简构建**——
 * `-muxers` 里没有 gif，`-filters` 里没有 palettegen/paletteuse，只能解码与导出 PNG 帧。
 * 所以走「ffmpeg 抽帧 → JS 量化编码」：
 *
 *   1. `ffmpeg -i demo.webm -vf fps=F,scale=W:-1 frames/%04d.png`（image2 导出，精简构建支持）
 *   2. `fast-png` 解码每帧 → `gifenc` 逐帧量化（256 色）+ 写帧
 *   3. 逐帧处理，不把 180 帧全读进内存（540×1170 一帧就要 2.5MB RGBA）
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import gifenc from 'gifenc';

// gifenc 是 CJS 包：ESM 下 default 导入拿到的就是导出对象本身（其 .default 是空壳，别再往下钻）
const { GIFEncoder, applyPalette, quantize } = gifenc;
import { decode } from 'fast-png';

const CACHE = join(homedir(), '.cache/ms-playwright');

function ffmpegPath() {
  for (const dir of readdirSync(CACHE)) {
    if (!dir.startsWith('ffmpeg-')) continue;
    const p = join(CACHE, dir, 'ffmpeg-linux');
    if (existsSync(p)) return p;
  }
  throw new Error('未找到 ms-playwright 缓存里的 ffmpeg-linux');
}

function expandToRgba(rgb, w, h) {
  const rgba = new Uint8Array(w * h * 4);
  for (let i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
    rgba[j] = rgb[i];
    rgba[j + 1] = rgb[i + 1];
    rgba[j + 2] = rgb[i + 2];
    rgba[j + 3] = 255;
  }
  return rgba;
}

/**
 * @param {string} video 录制的 webm
 * @param {string} out   目标 gif
 * @param {{fps?:number,width?:number}} opts
 * @returns {{size:number, frames:number}}
 */
/**
 * 判断一帧是否「基本是白的」：抽样统计非白像素比例。
 * 录屏开头页面还没渲染完，会有一段纯白，必须裁掉否则 GIF 第一屏是空白的。
 */
function contentRatio(data, channels) {
  const step = 40 * channels;
  let total = 0;
  let nonWhite = 0;
  for (let i = 0; i + 2 < data.length; i += step) {
    total += 1;
    if (data[i] < 245 || data[i + 1] < 245 || data[i + 2] < 245) nonWhite += 1;
  }
  return total ? nonWhite / total : 0;
}

export function videoToGif(video, out, { fps = 12, width = 540, skipFrames = 0, autoTrim = true } = {}) {
  const ff = ffmpegPath();
  const framesDir = join('/tmp', `qd-appt-frames-${Date.now()}`);
  mkdirSync(framesDir, { recursive: true });

  try {
    execFileSync(
      ff,
      // 这个精简构建里 `fps` 滤镜初始化会失败（报 output file invalid），用 `-r` 控制帧率；
      // `scale` 用 `-2`（保证偶数）而不是 `-1`
      ['-y', '-i', video, '-r', String(fps), '-vf', `scale=${width}:-2:flags=lanczos`, join(framesDir, '%04d.png')],
      { stdio: ['ignore', 'ignore', 'pipe'] }
    );

    const all = readdirSync(framesDir).filter((f) => f.endsWith('.png')).sort();
    let start = skipFrames;
    if (autoTrim) {
      // 往后找第一个「有内容」的帧，最多找 6 秒，避免整段白屏时把 GIF 裁没
      for (let i = skipFrames; i < Math.min(all.length, skipFrames + fps * 6); i += 1) {
        const png = decode(readFileSync(join(framesDir, all[i])));
        if (contentRatio(png.data, png.channels ?? 4) > 0.02) {
          start = i;
          break;
        }
      }
    }
    const frames = all.slice(start);
    if (!frames.length) throw new Error('抽帧结果为空：检查录制是否成功');

    const gif = GIFEncoder();
    const delay = Math.round(1000 / fps);

    for (const file of frames) {
      const png = decode(readFileSync(join(framesDir, file)));
      const { width: w, height: h, data, channels } = png;
      const rgba = channels === 4 ? data : expandToRgba(data, w, h);
      const palette = quantize(rgba, 256);
      gif.writeFrame(applyPalette(rgba, palette), w, h, { palette, delay });
    }

    gif.finish();
    writeFileSync(out, gif.bytes());
    return { size: statSync(out).size, frames: frames.length };
  } finally {
    rmSync(framesDir, { recursive: true, force: true });
  }
}
