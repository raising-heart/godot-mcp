/**
 * Keeps track of the game Claude started with run_project, and its output.
 */

import { ChildProcess, spawn } from 'child_process';
import { stripAnsi } from './godot.js';

export interface OutputLine {
  seq: number;
  stream: 'stdout' | 'stderr';
  text: string;
}

const MAX_LINES = 5000;
const PROBLEM_PATTERN = /\b(ERROR|SCRIPT ERROR|Parse Error|Compile Error|WARNING|USER ERROR|USER WARNING|Invalid call|Invalid access|Invalid get|Invalid set|Cannot call|Attempt to call|Nonexistent function|Null instance|crash|Segmentation fault|CrashHandlerException)\b/i;

export function isProblemLine(text: string): boolean {
  return PROBLEM_PATTERN.test(text);
}

export class GameRun {
  readonly startedAt = Date.now();
  readonly lines: OutputLine[] = [];
  exitCode: number | null = null;
  exited = false;
  stoppedByUser = false;
  droppedLines = 0;
  private nextSeq = 1;
  /** Highest seq already returned to the caller */
  readCursor = 0;
  private partial: Record<'stdout' | 'stderr', string> = { stdout: '', stderr: '' };
  private exitWaiters: Array<() => void> = [];

  constructor(
    readonly process: ChildProcess,
    readonly projectPath: string,
    readonly description: string
  ) {
    process.stdout?.on('data', (data: Buffer) => this.push('stdout', data.toString()));
    process.stderr?.on('data', (data: Buffer) => this.push('stderr', data.toString()));
    process.on('exit', (code) => this.finish(code));
    process.on('error', (err) => {
      this.push('stderr', `[godot-mcp] Failed to start Godot: ${err.message}\n`);
      this.finish(null);
    });
  }

  private push(stream: 'stdout' | 'stderr', chunk: string) {
    const text = this.partial[stream] + stripAnsi(chunk);
    const parts = text.split(/\r?\n/);
    this.partial[stream] = parts.pop() ?? '';
    for (const part of parts) this.add(stream, part);
  }

  private add(stream: 'stdout' | 'stderr', text: string) {
    if (!text.trim()) return;
    this.lines.push({ seq: this.nextSeq++, stream, text });
    if (this.lines.length > MAX_LINES) {
      this.lines.shift();
      this.droppedLines++;
    }
  }

  private finish(code: number | null) {
    if (this.exited) return;
    for (const stream of ['stdout', 'stderr'] as const) {
      if (this.partial[stream]) this.add(stream, this.partial[stream]);
      this.partial[stream] = '';
    }
    this.exited = true;
    this.exitCode = code;
    this.exitWaiters.splice(0).forEach((resolve) => resolve());
  }

  /** Resolve after `ms`, or earlier if the game exits. */
  waitForExit(ms: number): Promise<void> {
    if (this.exited || ms <= 0) return Promise.resolve();
    return new Promise((resolve) => {
      const timer = setTimeout(resolve, ms);
      this.exitWaiters.push(() => {
        clearTimeout(timer);
        resolve();
      });
    });
  }

  /**
   * A windowed game is only really started once Godot prints its renderer line
   * ("OpenGL API ...", "Vulkan ..."). The first launch can take several seconds,
   * so wait for that line (up to `ms`) and give the game one more second.
   */
  async waitForRendererStart(ms: number): Promise<void> {
    const deadline = Date.now() + ms;
    const isRendererLine = (text: string) => /^(OpenGL API|Vulkan |D3D12 |Metal )/.test(text);
    while (!this.exited && Date.now() < deadline && !this.lines.some((l) => isRendererLine(l.text))) {
      await this.waitForExit(Math.min(200, deadline - Date.now()));
    }
    const started = this.lines.find((l) => isRendererLine(l.text));
    if (started && !this.exited) {
      const sinceStart = this.lines[this.lines.length - 1] === started ? 1000 : 0;
      await this.waitForExit(sinceStart);
    }
  }

  stop() {
    if (this.exited) return;
    this.stoppedByUser = true;
    this.process.kill();
  }

  status(): string {
    const seconds = Math.round((Date.now() - this.startedAt) / 1000);
    if (!this.exited) return `running for ${seconds}s`;
    if (this.stoppedByUser) return `was stopped after ${seconds}s`;
    return `exited with code ${this.exitCode ?? 'unknown'} after ${seconds}s`;
  }

  /**
   * Format output for the AI. `onlyNew` returns lines not returned before;
   * `errorsOnly` keeps errors/warnings (plus the "at:" line under each).
   */
  read(options: { onlyNew: boolean; errorsOnly: boolean; tail: number }): string {
    let lines = options.onlyNew ? this.lines.filter((l) => l.seq > this.readCursor) : this.lines;
    if (this.lines.length) this.readCursor = this.lines[this.lines.length - 1].seq;

    if (options.errorsOnly) {
      lines = lines.filter((line, index) =>
        isProblemLine(line.text) || (index > 0 && isProblemLine(lines[index - 1].text) && /^\s+at:/.test(line.text))
      );
    }
    const omitted = Math.max(0, lines.length - options.tail);
    lines = lines.slice(-options.tail);

    const problems = this.lines.filter((l) => isProblemLine(l.text)).length;
    const header = [
      `Game ${this.status()} (${this.description}).`,
      problems ? `${problems} error/warning line(s) so far.` : 'No errors or warnings so far.',
    ];
    if (omitted) header.push(`(${omitted} earlier line(s) not shown; raise "tail" to see more.)`);
    if (this.droppedLines) header.push(`(${this.droppedLines} oldest line(s) were dropped from the buffer.)`);

    const body = lines.length
      ? lines.map((l) => (l.stream === 'stderr' ? `! ${l.text}` : `  ${l.text}`)).join('\n')
      : options.onlyNew ? '(no new output)' : '(no output yet)';
    return `${header.join(' ')}\n\n${body}`;
  }
}

export function startGame(godotPath: string, args: string[], projectPath: string, description: string): GameRun {
  const child = spawn(godotPath, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: false });
  return new GameRun(child, projectPath, description);
}
