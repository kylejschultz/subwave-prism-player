'use client';

// Gatefold - a cover-wash console skin. It keeps the prototype's translucent
// booth-glass feel while consuming only the shared SUB/WAVE player contexts.

import { useEffect, useMemo, useRef, useState, type RefObject } from 'react';
import * as Dialog from '@radix-ui/react-dialog';
import { Heart, Info, LoaderCircle, Play, RadioTower, Send, SlidersHorizontal, Square, Volume2, VolumeX, X } from 'lucide-react';
import styles from './Gatefold.module.css';
import {
  usePlayerActions,
  usePlayerAudio,
  usePlayerFeed,
} from '@/components/player/PlayerCore';
import { useStationTuner } from '@/components/player/StationTuner';
import { useTuneInGate } from '@/components/player/useTuneInGate';
import ThemeSwitcher from '@/components/ThemeSwitcher';
import { ScrollArea } from '@/components/ui/scroll-area';
import { useLiteMode } from '@/hooks/useLiteMode';
import { useCoverColors } from '@/hooks/useCoverColors';
import { useDynamicStyle } from '@/hooks/useDynamicStyle';
import { useElapsed } from '@/hooks/useElapsed';
import { useKeyboardShortcuts } from '@/hooks/useKeyboardShortcuts';
import { useAnalyser } from '@/lib/hooks';
import { cn } from '@/lib/cn';
import { fmtClockMinute, fmtTime, normalizeStationLocale, relTime, zonedDayHour } from '@/lib/format';
import { useStationClient } from '@/lib/stationClient';
import type { PublicLyricsPayload, QueueEntry, ScheduleGrid, SchedulePayload, ScheduleShow, StationLocale } from '@/lib/types';
import {
  boothLines,
  lastVoiceLine,
  listenerCountOf,
  progressRatio,
  stationIdentity,
  trackMeta,
} from '../shared';
import { useRequestSlip, useTrackLike, useVolumeNudge } from '../sharedHooks';
import type { SkinProps } from '../types';

function Label({ children }: { children: React.ReactNode }) {
  return (
    <span className="font-mono text-[10px] font-extrabold tracking-[0.18em] text-[var(--accent)] uppercase">
      {children}
    </span>
  );
}

function Tag({ children }: { children: React.ReactNode }) {
  return (
    <span className="border border-[var(--line)] bg-[color-mix(in_oklab,var(--bg)_34%,transparent)] px-2 py-1 font-mono text-[11px] font-bold text-[var(--accent-2)] uppercase">
      {children}
    </span>
  );
}

function titleCase(value: string): string {
  return value.replace(/\S+/g, word => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase());
}

function Panel({
  title,
  children,
  className,
  action,
}: {
  title: string;
  children: React.ReactNode;
  className?: string;
  action?: React.ReactNode;
}) {
  return (
    <section className={cn('relative flex min-h-0 min-w-0 flex-col overflow-hidden border', styles.quietGlass, className)}>
      <header className="relative z-10 flex min-h-9 items-center justify-between border-b border-[color-mix(in_oklab,var(--line)_66%,transparent)] px-3">
        <h2 className="truncate font-mono text-[10px] font-extrabold tracking-[0.22em] text-[var(--accent)] uppercase">
          {title}
        </h2>
        {action}
      </header>
      <div className="relative z-10 flex min-h-0 flex-1 flex-col">
        {children}
      </div>
    </section>
  );
}

function rowKey(entry: QueueEntry, prefix: string, index: number): string {
  return `${prefix}-${entry.t ?? ''}-${entry.title ?? ''}-${index}`;
}

function relativeTime(t: string | number | undefined): string {
  if (t == null) return 'just now';
  const at = new Date(t).getTime();
  if (Number.isNaN(at)) return 'just now';
  if (Date.now() - at < 1000) return 'now';
  return `${relTime(at)} ago`;
}

function turnTimeMs(t: string | number | undefined): number | null {
  if (t == null) return null;
  const at = new Date(t).getTime();
  return Number.isNaN(at) ? null : at;
}

function splitFeaturedTitle(title: string): { main: string; feature?: string } {
  const match = title.match(/\s+((?:feat\.?|ft\.?|featuring)\s+.+)$/i);
  if (!match?.index) return { main: title };
  return {
    main: title.slice(0, match.index).trim(),
    feature: match[1]?.trim(),
  };
}

function QueueRow({ entry, muted = false }: { entry: QueueEntry; muted?: boolean }) {
  return (
    <li className={cn('flex max-w-full min-w-0 items-baseline justify-between gap-3 border-b border-[color-mix(in_oklab,var(--line)_52%,transparent)] py-1.5 last:border-b-0', styles.sideRow)}>
      <div className="min-w-0 flex-1">
        <p className={cn('line-clamp-2 text-[13px] leading-snug font-semibold', styles.sideTrackTitle, muted ? styles.historyTitle : styles.sideTitle)}>
          {entry.title || 'Unknown'}
        </p>
        {entry.artist && <p className={cn('truncate text-[11px] leading-snug', styles.sideMeta)}>{entry.artist}</p>}
        {entry.album && <p className={cn('line-clamp-2 text-[10px] leading-snug', styles.sideAccent)}>{entry.album}</p>}
      </div>
      {entry.requestedBy && (
        <div className="max-w-[42%] shrink-0 text-right">
          <span className="block truncate bg-[var(--accent)] px-1.5 py-0.5 font-mono text-[9px] font-bold text-bg">
            request / {entry.requestedBy}
          </span>
        </div>
      )}
    </li>
  );
}

const LYRICS_OFFSET_KEY_PREFIX = 'subwave:lyrics-offset-ms:';

function clampLyricOffset(value: number): number {
  return Number.isFinite(value) ? Math.min(5000, Math.max(-5000, Math.round(value))) : 0;
}

function formatLyricOffset(value: number): string {
  if (value === 0) return '0.00s';
  return `${value > 0 ? '+' : '-'}${(Math.abs(value) / 1000).toFixed(2)}s`;
}

function lyricStorageKey(trackKey: string | null): string | null {
  return trackKey ? `${LYRICS_OFFSET_KEY_PREFIX}${trackKey}` : null;
}

function activeLyricIndex(payload: PublicLyricsPayload | null, elapsedMs: number, offsetMs = 0): number {
  if (!payload?.synced) return -1;
  const target = Math.max(0, elapsedMs + offsetMs);
  let active = -1;
  for (let i = 0; i < payload.lines.length; i += 1) {
    const startMs = payload.lines[i]?.startMs;
    if (startMs == null) continue;
    if (startMs > target) break;
    active = i;
  }
  return active;
}

const WAVE_BARS = 34;

function pad2(n: number): string {
  return n < 10 ? `0${n}` : String(n);
}

function fmtHour(hour: number, locale: StationLocale): string {
  if (locale === 'en-US') {
    const h = hour % 24;
    const suffix = h < 12 ? 'AM' : 'PM';
    return `${h % 12 || 12}:00 ${suffix}`;
  }
  return `${pad2(hour % 24)}:00`;
}

function endHourForCurrentBlock(grid: ScheduleGrid, day: number, hour: number): number {
  const dayGrid = grid[day];
  if (!Array.isArray(dayGrid)) return hour;
  const current = dayGrid[hour] ?? null;
  let h = hour;
  while (h + 1 < 24 && (dayGrid[h + 1] ?? null) === current) h++;
  return h;
}

function nextScheduledShow(
  data: SchedulePayload,
  day: number,
  hour: number,
): { show: ScheduleShow | null; startHour: number } | null {
  const showById = new Map(data.shows.map(show => [show.id, show]));
  const currentId = data.schedule[day]?.[hour] ?? null;
  for (let offset = 1; offset <= 24 * 7; offset++) {
    const absoluteHour = hour + offset;
    const candidateDay = (day + Math.floor(absoluteHour / 24)) % 7;
    const candidateHour = absoluteHour % 24;
    const id = data.schedule[candidateDay]?.[candidateHour] ?? null;
    if (id === currentId) continue;
    return {
      show: id ? showById.get(id) || null : null,
      startHour: candidateHour,
    };
  }
  return null;
}

function GatefoldWaveform({
  audioRef,
  active,
}: {
  audioRef: RefObject<HTMLAudioElement | null>;
  active: boolean;
}) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const levelsRef = useRef<Float32Array>(new Float32Array(WAVE_BARS));
  const { lite } = useLiteMode();
  const { ready, read } = useAnalyser(audioRef, active && !lite);

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext('2d');
    if (!canvas || !ctx) return;

    let raf = 0;
    const levels = levelsRef.current;

    const draw = () => {
      const dpr = Math.min(2, window.devicePixelRatio || 1);
      const w = canvas.clientWidth;
      const h = canvas.clientHeight;
      if (w === 0 || h === 0) {
        raf = requestAnimationFrame(draw);
        return;
      }
      const width = Math.round(w * dpr);
      const height = Math.round(h * dpr);
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;

      const css = getComputedStyle(canvas);
      const activeColor = css.getPropertyValue('--accent').trim() || '#21d9ef';
      const idleColor = css.getPropertyValue('--muted').trim() || '#7f8b94';
      const bins = active && ready && !lite ? read() : null;

      ctx.clearRect(0, 0, width, height);
      const gap = Math.max(1, 2 * dpr);
      const slot = width / WAVE_BARS;
      const barW = Math.max(1, slot - gap);

      for (let i = 0; i < WAVE_BARS; i++) {
        let target = 0.1;
        if (bins) {
          const start = Math.floor(Math.pow(i / WAVE_BARS, 1.45) * bins.length * 0.72);
          const end = Math.max(start + 1, Math.floor(Math.pow((i + 1) / WAVE_BARS, 1.45) * bins.length * 0.72));
          let sum = 0;
          for (let b = start; b < end; b++) sum += bins[b] ?? 0;
          const raw = sum / (end - start) / 255;
          target = Math.max(0.1, Math.pow(raw, 0.62) * (0.86 - i / (WAVE_BARS * 5)));
        } else if (active && !lite) {
          target = Math.max(0.1, 0.12 + Math.pow(Math.random(), 1.8) * (1 - i / (WAVE_BARS * 2.5)) * 0.58);
        }

        const current = levels[i] ?? 0;
        const next = current + (target - current) * 0.34;
        levels[i] = next;
        const barH = Math.max(1, next * height);
        const x = i * slot;
        const y = height - barH;
        ctx.fillStyle = active ? activeColor : idleColor;
        ctx.fillRect(x, y, barW, barH);
      }

      raf = requestAnimationFrame(draw);
    };

    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, [active, ready, read, lite]);

  return <canvas ref={canvasRef} className="h-full w-full" aria-hidden="true" />;
}

export default function GatefoldSkin(_props: SkinProps) {
  const client = useStationClient();
  const tuner = useStationTuner();
  const {
    nowPlaying, context, dj, activeShow, listeners, state, session,
    trackStartedAt, timezone, locale,
  } = usePlayerFeed();
  const { audioRef, tunedIn, status, volume, muted, offline, signal } = usePlayerAudio();
  const { toggleMute, setVolume } = usePlayerActions();
  const { showOverlay, tuneInFromOverlay, handleTune } = useTuneInGate();

  const elapsed = useElapsed(trackStartedAt);
  const listenerCount = listenerCountOf(listeners);
  const { stationName, djName, showName } = stationIdentity(dj, activeShow, context);
  const meta = trackMeta(nowPlaying);
  const heroTags = [...meta.facts, ...meta.moods]
    .filter(tag => !tag.endsWith(' BPM') && !/^\d{1,2}[AB]$/i.test(tag))
    .slice(0, 4);
  const ratio = progressRatio(elapsed, nowPlaying?.duration);
  const playing = tunedIn && status === 'playing' && !offline;
  const connecting = tunedIn && status === 'connecting' && !offline;
  const coverId = nowPlaying?.subsonic_id ?? null;
  const coverSrc = coverId ? client.coverUrl(coverId) : null;
  const colors = useCoverColors(coverSrc);

  const rootRef = useRef<HTMLDivElement | null>(null);
  const title = offline ? '- off air -' : (nowPlaying?.title ?? 'Scanning the dial...');
  const titleParts = splitFeaturedTitle(title);
  const artist = offline ? '' : (nowPlaying?.artist ?? '');
  const weather = context?.weather;
  const weatherTemp = weather?.temp != null ? `${Math.round(weather.temp)} degrees` : '';
  const weatherCondition = weather?.condition ? titleCase(weather.condition) : '';
  const weatherLocation = weather?.location ? titleCase(weather.location) : '';
  const weatherSummary =
    weatherTemp && weatherCondition
      ? `${weatherTemp} and ${weatherCondition}`
      : weatherTemp || weatherCondition || '';
  const latestVoice = lastVoiceLine(session.messages);
  const voiceTime = turnTimeMs(latestVoice?.t);
  const [boothClock, setBoothClock] = useState(() => Date.now());
  const [schedule, setSchedule] = useState<SchedulePayload | null>(null);
  const voiceBelongsToTrack =
    latestVoice != null &&
    (trackStartedAt == null || voiceTime == null || voiceTime >= trackStartedAt - 45000);
  const voiceFresh = voiceTime == null || boothClock - voiceTime <= 5 * 60 * 1000;
  const voice = voiceBelongsToTrack && voiceFresh ? latestVoice : null;
  const voiceAge = relativeTime(voice?.t);
  const spokenLines = boothLines(session.messages, 24)
    .filter(line => line.kind === 'voice')
    .slice(-5)
    .reverse();
  const upNext = (state.upcoming ?? []).slice(0, 1);
  const playHistory = (state.history ?? []).slice(0, 6);
  const showLine = showName ? `${showName} with ${djName}` : `with ${djName}`;
  const listenerLine = listenerCount == null
    ? null
    : `${listenerCount} ${listenerCount === 1 ? 'person' : 'people'} tuned in`;
  const nowPlayingLabel = listenerCount == null
    ? 'now playing'
    : `now playing for ${listenerCount} ${listenerCount === 1 ? 'listener' : 'listeners'}`;
  const weatherLine = offline ? 'Off air' : '';
  const statusLine = offline ? 'off air' : playing ? 'on air' : tunedIn ? status : 'ready';
  const scheduleLocale = normalizeStationLocale(schedule?.locale ?? locale);
  const scheduleTimezone = schedule?.timezone ?? timezone;
  const stationTime = fmtClockMinute(boothClock, scheduleTimezone, scheduleLocale);
  const showTiming = useMemo(() => {
    if (!schedule) return null;
    const { dow, hour } = zonedDayHour(new Date(boothClock), scheduleTimezone);
    const endHour = endHourForCurrentBlock(schedule.schedule, dow, hour);
    const next = nextScheduledShow(schedule, dow, hour);
    return {
      until: `until ${fmtHour((endHour + 1) % 24, scheduleLocale)}`,
      next: next
        ? `${next.show?.name || 'Autonomous'} at ${fmtHour(next.startHour, scheduleLocale)}`
        : 'No later show',
    };
  }, [boothClock, schedule, scheduleLocale, scheduleTimezone]);

  const slip = useRequestSlip({
    sent: 'Request received - the DJ has it.',
    refused: 'The booth waved this one off.',
    failed: 'The booth line is down - try again in a moment.',
  });
  const requestRef = useRef<HTMLInputElement | null>(null);
  const [requestOpen, setRequestOpen] = useState(false);
  const [infoOpen, setInfoOpen] = useState(false);
  const [playerUrl, setPlayerUrl] = useState('');
  const titleRef = useRef<HTMLHeadingElement | null>(null);
  const [titleFit, setTitleFit] = useState(1);
  const [lyricsPayload, setLyricsPayload] = useState<PublicLyricsPayload | null>(null);
  const [lyricsLoading, setLyricsLoading] = useState(false);
  const [lyricsFailed, setLyricsFailed] = useState(false);
  const [lyricsNow, setLyricsNow] = useState(() => Date.now());
  const [lyricsOffsetMs, setLyricsOffsetMs] = useState(0);
  const [lyricsOffsetOpen, setLyricsOffsetOpen] = useState(false);
  const activeLyricRef = useRef<HTMLDivElement | null>(null);
  const lyricsScrollerRef = useRef<HTMLDivElement | null>(null);
  const like = useTrackLike();
  const adjustVolume = useVolumeNudge();
  const volumePercent = Math.round(volume * 100);
  const openRequest = () => {
    setRequestOpen(true);
    requestAnimationFrame(() => requestRef.current?.focus());
  };

  useDynamicStyle(rootRef, {
    '--gatefold-wash-a': colors.vibrant
      ? `color-mix(in oklab, ${colors.vibrant} 32%, transparent)`
      : undefined,
    '--gatefold-wash-b': colors.average
      ? `color-mix(in oklab, ${colors.average} 28%, transparent)`
      : undefined,
    '--gatefold-progress': `${Math.round((ratio ?? 0.12) * 100)}%`,
    '--gatefold-title-fit': `${titleFit}`,
    '--gatefold-volume': `${volumePercent}%`,
  });

  useKeyboardShortcuts({
    space: handleTune,
    k: handleTune,
    arrowup: () => adjustVolume(0.05),
    arrowdown: () => adjustVolume(-0.05),
    m: toggleMute,
    r: openRequest,
  });

  useEffect(() => {
    const id = window.setInterval(() => setBoothClock(Date.now()), 30_000);
    return () => window.clearInterval(id);
  }, []);

  const lyricsTrackKey = useMemo(() => {
    if (lyricsPayload?.songId) return lyricsPayload.songId;
    if (coverId) return coverId;
    if (nowPlaying?.title || nowPlaying?.artist) {
      return [nowPlaying?.title, nowPlaying?.artist, nowPlaying?.album].filter(Boolean).join('::');
    }
    return null;
  }, [coverId, lyricsPayload?.songId, nowPlaying?.album, nowPlaying?.artist, nowPlaying?.title]);

  const setLyricOffset = (next: number) => {
    const clamped = clampLyricOffset(next);
    setLyricsOffsetMs(clamped);
    try {
      const key = lyricStorageKey(lyricsTrackKey);
      if (key) window.localStorage.setItem(key, String(clamped));
    } catch {}
  };

  useEffect(() => {
    let cancelled = false;
    setLyricsPayload(null);
    setLyricsFailed(false);
    if (!coverId || offline || !tunedIn) {
      setLyricsLoading(false);
      return;
    }
    setLyricsLoading(true);
    client
      .currentLyrics()
      .then(data => {
        if (cancelled) return;
        setLyricsPayload(data?.songId === coverId ? data : null);
        setLyricsFailed(data == null);
      })
      .finally(() => {
        if (!cancelled) setLyricsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [client, coverId, offline, tunedIn]);

  useEffect(() => {
    setLyricsNow(Date.now());
    setLyricsOffsetOpen(false);
    lyricsScrollerRef.current?.scrollTo({ top: 0 });
    const key = lyricStorageKey(lyricsTrackKey);
    try {
      const stored = key ? window.localStorage.getItem(key) : null;
      setLyricsOffsetMs(clampLyricOffset(stored != null ? Number(stored) : lyricsPayload?.offsetMs ?? 0));
    } catch {
      setLyricsOffsetMs(clampLyricOffset(lyricsPayload?.offsetMs ?? 0));
    }
  }, [lyricsPayload?.offsetMs, lyricsTrackKey, trackStartedAt]);

  useEffect(() => {
    if (!lyricsPayload?.synced) return;
    const id = window.setInterval(() => setLyricsNow(Date.now()), 500);
    return () => window.clearInterval(id);
  }, [lyricsPayload?.synced, lyricsTrackKey, trackStartedAt]);

  const lyricElapsedMs = trackStartedAt == null ? 0 : Math.max(0, lyricsNow - trackStartedAt);
  const activeLyric = useMemo(
    () => activeLyricIndex(lyricsPayload, lyricElapsedMs, lyricsOffsetMs),
    [lyricsPayload, lyricElapsedMs, lyricsOffsetMs],
  );
  const showLyricsPanel = tunedIn && !offline && Boolean(coverId);

  useEffect(() => {
    if (activeLyric < 0) return;
    const scroller = lyricsScrollerRef.current;
    const activeLine = activeLyricRef.current;
    if (!scroller || !activeLine) return;
    const top = activeLine.offsetTop - (scroller.clientHeight / 2) + (activeLine.clientHeight / 2);
    scroller.scrollTo({ top: Math.max(0, top), behavior: 'smooth' });
  }, [activeLyric]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const data = await client.schedule();
        if (!cancelled) setSchedule(data);
      } catch {
        if (!cancelled) setSchedule(null);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [client]);

  useEffect(() => {
    setPlayerUrl(window.location.href);
  }, []);

  useEffect(() => {
    const el = titleRef.current;
    if (!el) return;

    const fitTitle = () => {
      el.style.setProperty('--gatefold-title-fit', '1');
      const viewportWide = window.matchMedia('(min-width: 1180px)').matches;
      const minScale = viewportWide ? 0.46 : 0.44;
      const width = el.clientWidth;
      const scrollWidth = el.scrollWidth;
      const lineHeight = Number.parseFloat(getComputedStyle(el).lineHeight);
      const maxHeight = Number.isFinite(lineHeight) ? lineHeight * 2.04 : el.clientHeight;
      const scrollHeight = el.scrollHeight;
      if (!width || !scrollWidth) {
        el.style.removeProperty('--gatefold-title-fit');
        setTitleFit(1);
        return;
      }
      const widthFit = scrollWidth > width ? (width / scrollWidth) * 0.985 : 1;
      const heightFit = scrollHeight > maxHeight ? (maxHeight / scrollHeight) * 0.985 : 1;
      el.style.removeProperty('--gatefold-title-fit');
      setTitleFit(Math.max(minScale, Math.min(1, widthFit, heightFit)));
    };

    fitTitle();
    const ro = new ResizeObserver(fitTitle);
    ro.observe(el);
    window.addEventListener('resize', fitTitle);
    return () => {
      ro.disconnect();
      window.removeEventListener('resize', fitTitle);
    };
  }, [title]);

  return (
    <div ref={rootRef} className={cn('absolute inset-0 overflow-hidden font-sans text-ink', styles.shell)}>
      <div className={cn('pointer-events-none absolute inset-0', styles.background)} aria-hidden="true">
        {coverSrc && !offline && (
          <>
            <img
              src={coverSrc}
              alt=""
              className="absolute inset-[-7%] h-[114%] w-[114%] scale-105 object-cover opacity-55 blur-3xl saturate-150"
            />
            <img
              src={coverSrc}
              alt=""
              className="absolute inset-0 h-full w-full object-cover opacity-[0.14] blur-[1px] saturate-125"
            />
          </>
        )}
      </div>

      <div className="relative z-10 flex h-full min-h-0 w-full max-w-full flex-col overflow-hidden px-4 py-4 sm:px-6 sm:py-5">
        <div className="grid min-h-0 min-w-0 flex-1 grid-cols-1 gap-4 overflow-y-auto min-[1180px]:grid-cols-[minmax(0,1fr)_minmax(270px,320px)] min-[1180px]:overflow-hidden">
          <main className={cn('relative overflow-visible border min-[1180px]:min-h-0 min-[1180px]:overflow-hidden', styles.glass)}>
            <div className={cn('pointer-events-none absolute inset-0', styles.stageScrim)} aria-hidden="true" />
            <div className={cn('relative z-10 grid min-w-0 grid-cols-1 gap-6 p-4 min-[1180px]:h-full min-[1180px]:min-h-0 min-[1180px]:grid-cols-[minmax(300px,43vh)_minmax(0,1fr)] min-[1180px]:p-6 xl:grid-cols-[minmax(360px,52vh)_minmax(0,1fr)]', styles.stageGrid)}>
              <div className={cn('contents min-[1180px]:flex min-[1180px]:min-w-0 min-[1180px]:flex-col min-[1180px]:justify-start min-[1180px]:gap-5', styles.coverColumn)}>
                <div className={cn('relative order-1 aspect-square w-full max-w-[460px] self-center overflow-hidden border border-[color-mix(in_oklab,var(--line)_62%,transparent)] bg-[color-mix(in_oklab,var(--bg)_34%,transparent)] shadow-2xl shadow-[color-mix(in_oklab,var(--bg)_72%,transparent)] min-[1180px]:max-w-none min-[1180px]:self-auto', styles.coverArt)}>
                  {coverSrc && !offline ? (
                    <img src={coverSrc} alt={nowPlaying?.album || nowPlaying?.title || ''} className="h-full w-full object-cover" />
                  ) : (
                    <div className="grid h-full w-full place-items-center bg-[radial-gradient(circle_at_35%_25%,var(--accent-soft),transparent_32%),linear-gradient(135deg,var(--surface),var(--bg))]">
                      <span className="font-mono text-[10px] tracking-[0.24em] text-muted uppercase">no cover</span>
                    </div>
                  )}
                </div>

                <div className="order-3 min-[1180px]:hidden" />
              </div>

              <div className={cn('order-2 flex min-w-0 flex-col justify-start gap-4 py-2 min-[1180px]:order-none min-[1180px]:h-full min-[1180px]:py-0', styles.contentStack)}>
                <div className="min-w-0">
                  <span className="bg-[var(--accent)] px-2 py-1 font-mono text-[10px] font-black text-bg uppercase">
                    {nowPlayingLabel}
                  </span>
                  <h1
                    ref={titleRef}
                    className={cn('mt-5 max-w-5xl font-black text-ink', styles.title)}
                  >
                    <span>{titleParts.main}</span>
                    {titleParts.feature && (
                      <>
                        {' '}
                        <span className={styles.titleFeature}>{titleParts.feature}</span>
                      </>
                    )}
                  </h1>
                  {artist && (
                    <p className={cn('mt-3 font-semibold text-[var(--accent)]', styles.artistLine)}>
                      {artist}
                    </p>
                  )}
                  {(nowPlaying?.album || nowPlaying?.year) && !offline && (
                    <p className={cn('mt-1 text-[var(--accent-2)]', styles.albumLine)}>
                      {nowPlaying?.album || 'Unknown album'}
                      {nowPlaying?.year ? ` / ${nowPlaying.year}` : ''}
                    </p>
                  )}
                  {heroTags.length > 0 && (
                    <div className={cn('mt-5 flex flex-wrap items-center gap-2', styles.tagRail)}>
                      {heroTags.map(tag => <Tag key={tag}>{tag}</Tag>)}
                    </div>
                  )}
                </div>

                <div className={styles.boothCardWrap}>
                  <div className="border-l-2 border-[var(--accent)] bg-[color-mix(in_oklab,var(--bg)_30%,transparent)] px-3 py-2.5 backdrop-blur-md">
                    <div className="mb-1 flex items-center justify-between gap-2">
                      <Label>From the booth</Label>
                      {voice && <span className="font-mono text-[10px] text-muted">{voiceAge}</span>}
                    </div>
                    <p className={cn('text-sm leading-snug font-semibold text-[var(--accent-2)]', styles.micText, !voice && styles.quietMic)}>
                      {voice ? voice.text : 'Quiet in the booth...'}
                    </p>
                  </div>
                </div>

                <div className={styles.transportProgress}>
                  <div className="h-2 w-full overflow-hidden bg-[color-mix(in_oklab,var(--bg)_78%,var(--ink))]">
                    <div className={cn('h-full bg-[var(--accent)] transition-[width] duration-1000 ease-linear', styles.progress)} />
                  </div>
                  <div className="mt-1.5 flex justify-between font-mono text-[11px] text-muted tabular-nums">
                    <span>{fmtTime(elapsed)}</span>
                    <span>{nowPlaying?.duration ? fmtTime(nowPlaying.duration) : 'live'}</span>
                  </div>
                </div>

                <div className={styles.controlRail}>
                  <div className={styles.controlCluster}>
                    <button
                      type="button"
                      onClick={offline ? undefined : handleTune}
                      disabled={offline}
                      aria-label={offline ? 'Stream offline' : tunedIn ? 'Tune out' : 'Tune in'}
                      title={offline ? 'The station is currently off air' : tunedIn ? 'Tune out' : 'Tune in'}
                      className={cn(
                        styles.controlButton,
                        styles.primaryControl,
                        offline ? 'cursor-default opacity-50' : 'cursor-pointer',
                      )}
                    >
                      {connecting ? (
                        <LoaderCircle aria-hidden className="size-5 animate-spin" />
                      ) : tunedIn ? (
                        <Square aria-hidden className="size-5 fill-current" />
                      ) : (
                        <Play aria-hidden className="size-5 fill-current" />
                      )}
                    </button>
                    <button
                      type="button"
                      onClick={toggleMute}
                      aria-pressed={muted}
                      aria-label={muted ? 'Unmute' : 'Mute'}
                      className={cn(
                        styles.controlButton,
                        muted && styles.activeControl,
                      )}
                    >
                      {muted ? <VolumeX aria-hidden className="size-5" /> : <Volume2 aria-hidden className="size-5" />}
                    </button>
                    {like.available && (
                      <button
                        type="button"
                        onClick={() => void like.like()}
                        disabled={like.pending || like.liked}
                        aria-pressed={like.liked}
                        aria-label={like.liked ? 'Liked' : 'Like this track'}
                        className={cn(
                          styles.controlButton,
                          like.liked && styles.activeControl,
                          like.pending && 'opacity-60',
                        )}
                      >
                        <Heart aria-hidden className={cn('size-5', like.liked && 'fill-current')} />
                      </button>
                    )}
                  </div>
                  <div className={styles.volumeRocker}>
                    <input
                      type="range"
                      min={0}
                      max={100}
                      value={volumePercent}
                      onChange={e => setVolume(Number(e.target.value) / 100)}
                      aria-label="Volume"
                      className={styles.volumeHorizontal}
                    />
                    <span className="font-mono text-[10px] font-bold text-[var(--accent-2)] tabular-nums">
                      {volumePercent}
                    </span>
                  </div>
                  <div className={styles.controlCluster}>
                    <Dialog.Root open={infoOpen} onOpenChange={setInfoOpen}>
                      <Dialog.Trigger asChild>
                        <button
                          type="button"
                          className={styles.controlButton}
                          aria-label="Station info"
                        >
                          <Info aria-hidden className="size-5" />
                        </button>
                      </Dialog.Trigger>
                      <Dialog.Portal>
                        <Dialog.Overlay className="fixed inset-0 z-40 bg-[color-mix(in_oklab,var(--bg)_72%,transparent)] backdrop-blur-md" />
                        <Dialog.Content
                          aria-describedby={undefined}
                          className={cn(
                            'fixed top-1/2 left-1/2 z-50 flex max-h-[calc(100vh-3rem)] w-[min(420px,calc(100vw-2rem))] -translate-x-1/2 -translate-y-1/2 flex-col border text-ink outline-none',
                            styles.quietGlass,
                            styles.gatefoldDialog,
                          )}
                        >
                          <div className="flex items-center justify-between gap-3 border-b border-[color-mix(in_oklab,var(--line)_58%,transparent)] px-4 py-3">
                            <Dialog.Title className="font-mono text-[11px] font-extrabold tracking-[0.24em] text-[var(--accent)] uppercase">
                              Station info
                            </Dialog.Title>
                            <Dialog.Close
                              className="v3-focus grid size-8 place-items-center border border-[var(--line)] text-muted hover:text-ink"
                              aria-label="Close station info"
                            >
                              <X aria-hidden className="size-4" />
                            </Dialog.Close>
                          </div>
                          <div className={styles.infoGrid}>
                            <span>Station</span><strong>{stationName}</strong>
                            <span>Show</span><strong>{showLine}</strong>
                            {listenerLine && <><span>Listeners</span><strong>{listenerLine}</strong></>}
                            <span>Status</span><strong>{statusLine}</strong>
                            {signal.latencyMs != null && tunedIn && <><span>Latency</span><strong>{signal.latencyMs} ms</strong></>}
                            {playerUrl && <><span>Player</span><strong className="truncate">{playerUrl}</strong></>}
                          </div>
                          {tuner?.setupRequired && (
                            <div className="border-t border-[color-mix(in_oklab,var(--line)_58%,transparent)] p-3">
                              <button
                                type="button"
                                onClick={() => {
                                  setInfoOpen(false);
                                  tuner.openSetup();
                                }}
                                className="v3-focus flex h-10 w-full items-center justify-center gap-2 border border-[var(--line)] bg-[color-mix(in_oklab,var(--surface)_42%,transparent)] px-3 font-mono text-[10px] font-extrabold tracking-[0.18em] text-[var(--accent)] uppercase hover:border-[var(--accent)]"
                              >
                                <RadioTower aria-hidden className="size-4" />
                                Change station
                              </button>
                            </div>
                          )}
                        </Dialog.Content>
                      </Dialog.Portal>
                    </Dialog.Root>
                    <button
                      type="button"
                      onClick={openRequest}
                      className={styles.controlButton}
                      aria-label="Request a track"
                    >
                      <Send aria-hidden className="size-5" />
                    </button>
                    <span className={cn(styles.controlButton, styles.themeSlot)}>
                      <ThemeSwitcher />
                    </span>
                  </div>
                </div>
              </div>

              <div className={styles.signalFloor}>
                <div className={styles.footerWave}>
                  <GatefoldWaveform audioRef={audioRef} active={playing} />
                </div>
                <div className={styles.footerPanel}>
                  <div className={styles.footerMeta}>
                    <div>
                      <Label>Station</Label>
                      <p>{weatherLine || stationName}</p>
                      <span className={styles.footerDetail}>
                        {weatherSummary || weatherLocation || statusLine}
                      </span>
                    </div>
                    <div>
                      <Label>Program</Label>
                      <p>{showLine}</p>
                      <span className={styles.footerDetail}>
                        {showTiming?.until || stationTime}
                      </span>
                    </div>
                  </div>
                  <div className={styles.footerLyrics}>
                    <div className={styles.lyricsHeader}>
                      <Label>Lyrics</Label>
                      <div className={styles.lyricsTools}>
                        {showLyricsPanel && lyricsPayload?.synced && (
                          <button
                            type="button"
                            onClick={() => setLyricsOffsetOpen(value => !value)}
                            className={cn(styles.lyricsToolButton, lyricsOffsetOpen && styles.activeControl)}
                            aria-pressed={lyricsOffsetOpen}
                            aria-label="Configure lyric timing offset"
                            title="Configure lyric timing offset"
                          >
                            <SlidersHorizontal aria-hidden className="size-3.5" />
                            <span>{formatLyricOffset(lyricsOffsetMs)}</span>
                          </button>
                        )}
                      </div>
                    </div>

                    {showLyricsPanel && lyricsPayload?.synced && lyricsOffsetOpen && (
                      <div className={styles.lyricsOffset}>
                        <button type="button" onClick={() => setLyricOffset(lyricsOffsetMs - 100)} aria-label="Delay lyrics">-</button>
                        <input
                          type="range"
                          min={-5000}
                          max={5000}
                          step={50}
                          value={lyricsOffsetMs}
                          onChange={event => setLyricOffset(Number(event.target.value))}
                          aria-label="Lyric offset"
                        />
                        <button type="button" onClick={() => setLyricOffset(lyricsOffsetMs + 100)} aria-label="Advance lyrics">+</button>
                        <button type="button" onClick={() => setLyricOffset(0)}>Zero</button>
                      </div>
                    )}

                    <div ref={lyricsScrollerRef} className={styles.lyricsScroller}>
                      {!showLyricsPanel ? (
                        <p>Tune in to show synced lyrics for the current track.</p>
                      ) : lyricsLoading ? (
                        <p>Pulling lyrics from the library...</p>
                      ) : lyricsFailed ? (
                        <p>Lyrics are not reachable right now.</p>
                      ) : !lyricsPayload?.lines.length ? (
                        <p>{nowPlaying?.title ? `${nowPlaying.title} has no lyrics indexed yet.` : 'No lyrics indexed yet.'}</p>
                      ) : (
                        lyricsPayload.lines.map((line, index) => {
                          const active = index === activeLyric;
                          return (
                            <div
                              key={`${line.startMs ?? 'plain'}-${index}`}
                              ref={active ? activeLyricRef : undefined}
                              className={cn(
                                styles.lyricLine,
                                active && styles.lyricLineActive,
                                !lyricsPayload.synced && styles.lyricLinePlain,
                              )}
                            >
                              {line.text}
                            </div>
                          );
                        })
                      )}
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </main>

          <aside className={cn('grid min-h-0 min-w-0 gap-3 min-[1180px]:grid-rows-[118px_minmax(0,1fr)_190px]', styles.sideRail)}>
            <Panel title="Up next" className="h-[118px]">
              <div className="min-h-0 px-3 py-1">
                {upNext.length > 0 ? (
                  <ul>{upNext.map((e, i) => <QueueRow key={rowKey(e, 'up', i)} entry={e} />)}</ul>
                ) : (
                  <p className="py-7 text-center text-sm text-muted">Nothing queued yet.</p>
                )}
              </div>
            </Panel>

            <Panel title="Play history">
              <ScrollArea className="min-h-0 flex-1">
                <div className="px-3 py-1">
                  {playHistory.length > 0 ? (
                    <ul>{playHistory.map((e, i) => <QueueRow key={rowKey(e, 'history', i)} entry={e} muted />)}</ul>
                  ) : (
                    <p className="py-8 text-center text-sm text-muted">Nothing played yet.</p>
                  )}
                </div>
              </ScrollArea>
            </Panel>

            <Panel title="Booth feed" className="h-[190px]">
              <ScrollArea className="min-h-0 flex-1">
                <div className="px-4 py-2">
                  {spokenLines.length > 0 ? (
                    spokenLines.map((line, i) => (
                      <article key={`${line.t ?? i}-${i}`} className={styles.boothLine}>
                        <div className="mb-1 flex items-center justify-between gap-2 font-mono text-[9px] font-bold tracking-[0.16em] text-muted uppercase">
                          <span className="min-w-0 truncate">{djName}</span>
                          <span className="shrink-0">{relativeTime(line.t)}</span>
                        </div>
                        <p className="text-[11.5px] leading-snug">
                          {line.text}
                        </p>
                      </article>
                    ))
                  ) : (
                    <p className="py-8 text-center text-sm text-muted">Quiet booth.</p>
                  )}
                </div>
              </ScrollArea>
            </Panel>
          </aside>
        </div>

      </div>

      {requestOpen && (
        <div className="absolute inset-0 z-40 flex items-end justify-center px-4 pb-24 sm:items-center sm:pb-0">
          <button
            type="button"
            aria-label="Close request panel"
            className="absolute inset-0 cursor-default bg-[color-mix(in_oklab,var(--bg)_62%,transparent)] backdrop-blur-sm"
            onClick={() => setRequestOpen(false)}
          />
          <form
            className={cn('relative z-10 flex w-full max-w-sm min-w-0 flex-col border p-4', styles.quietGlass)}
            onSubmit={e => { e.preventDefault(); void slip.send(); }}
          >
            <div className="mb-3 flex items-center justify-between gap-3">
              <Label>Request</Label>
              <button
                type="button"
                onClick={() => setRequestOpen(false)}
                className="v3-focus grid size-8 place-items-center border border-[var(--line)] text-muted hover:text-ink"
                aria-label="Close request panel"
              >
                <X aria-hidden className="size-4" />
              </button>
            </div>
            {slip.ack ? (
              <div className="grid gap-4">
                <p className="text-sm leading-snug text-[var(--accent-2)]">{slip.ack}</p>
                <button
                  type="button"
                  onClick={slip.reset}
                  className="v3-focus self-start border-0 bg-transparent p-0 font-mono text-[10px] font-bold tracking-[0.16em] text-muted uppercase hover:text-ink"
                >
                  new request
                </button>
              </div>
            ) : (
              <>
                <input
                  ref={requestRef}
                  value={slip.text}
                  onChange={e => slip.setText(e.target.value)}
                  placeholder="Song, artist, or vibe..."
                  maxLength={200}
                  className="v3-focus h-10 min-w-0 border border-[var(--line)] bg-[color-mix(in_oklab,var(--bg)_36%,transparent)] px-3 text-sm text-ink outline-none placeholder:text-muted"
                />
                <div className="mt-2 flex min-w-0 gap-2">
                  <input
                    value={slip.name}
                    onChange={e => slip.setName(e.target.value)}
                    placeholder="Name optional"
                    maxLength={40}
                    className="v3-focus h-10 min-w-0 flex-1 border border-[var(--line)] bg-[color-mix(in_oklab,var(--bg)_36%,transparent)] px-3 text-sm text-ink outline-none placeholder:text-muted"
                  />
                  <button
                    type="submit"
                    disabled={slip.sending || !slip.text.trim()}
                    className={cn(
                      'v3-focus grid h-10 w-12 place-items-center border border-[var(--accent)] text-[var(--accent)]',
                      slip.sending || !slip.text.trim()
                        ? 'cursor-default opacity-45'
                        : 'cursor-pointer bg-[color-mix(in_oklab,var(--accent)_10%,transparent)] hover:bg-[var(--overlay)]',
                    )}
                    aria-label="Send request"
                  >
                    <Send aria-hidden className="size-4" />
                  </button>
                </div>
              </>
            )}
          </form>
        </div>
      )}

      {showOverlay && !offline && (
        <button
          type="button"
          onClick={tuneInFromOverlay}
          className="v3-focus absolute inset-0 z-50 grid cursor-pointer place-items-center bg-[color-mix(in_oklab,var(--bg)_90%,transparent)] px-6 text-center backdrop-blur-md"
        >
          <span className="max-w-2xl">
            <span className="block font-mono text-[11px] font-extrabold tracking-[0.26em] text-[var(--accent)] uppercase">
              {stationName}
            </span>
            <span className="mt-3 block text-4xl leading-tight font-black sm:text-5xl">Tap anywhere to tune in</span>
            <span className="mx-auto mt-4 block max-w-sm text-sm text-muted">
              Audio unlocks after your first click.
            </span>
          </span>
        </button>
      )}
    </div>
  );
}
