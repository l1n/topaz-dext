/**
 * topaz.d.ts — Type definitions for Topaz Signature Pad Library
 */

export interface TopazModelConfig {
  xStart: number;
  xStop: number;
  yStart: number;
  yStop: number;
  logicalX: number;
  logicalY: number;
  baud: number;
  filter: number;
  fmt: number;
}

export type TopazModelName =
  | 'SignatureGem1X5'
  | 'SignatureGemLCD1X5'
  | 'SignatureGem4X5'
  | 'SigLite1X5'
  | 'SigLiteLCD1X5'
  | 'SigLiteLCD4X5'
  | 'ClipGem'
  | 'SigGemColor57';

export declare const MODELS: Record<TopazModelName, TopazModelConfig>;

export interface Point {
  x: number;
  y: number;
  p: number;
}

export type Stroke = Point[];

export interface Bounds {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

export interface DeviceInfo {
  model: number;
  serial: number;
}

export interface RenderOptions {
  inkColor?: string;
  inkWidth?: number;
  padding?: number;
  scale?: number;
}

export type TopazEvent = 'connect' | 'disconnect' | 'pendown' | 'penup' | 'point' | 'stroke' | 'pressure' | 'info' | 'error' | 'clear';

export declare function rdpSimplify(pts: Point[], epsilon: number): Point[];
export declare function stabilize(pts: Point[], level?: number): Point[];
export declare function strokesBounds(strokes: Stroke[], inkWidth?: number): Bounds;
export declare function toSVG(strokes: Stroke[], opts?: RenderOptions): string;
export declare function toCanvas(strokes: Stroke[], opts?: RenderOptions): HTMLCanvasElement;
export declare function toPNG(strokes: Stroke[], opts?: RenderOptions): Promise<Blob>;
export declare function toSigString(strokes: Stroke[]): string;

export declare class TopazPad {
  constructor(model?: TopazModelName);

  readonly model: TopazModelConfig;
  readonly modelName: string;
  readonly connected: boolean;
  strokes: Stroke[];
  currentStroke: Stroke;
  penDown: boolean;
  pressure: number;
  totalPoints: number;

  on(event: 'connect', fn: () => void): this;
  on(event: 'disconnect', fn: () => void): this;
  on(event: 'pendown', fn: (point: Point) => void): this;
  on(event: 'penup', fn: () => void): this;
  on(event: 'point', fn: (point: Point) => void): this;
  on(event: 'stroke', fn: (stroke: Stroke) => void): this;
  on(event: 'pressure', fn: (pressure: number) => void): this;
  on(event: 'info', fn: (info: DeviceInfo) => void): this;
  on(event: 'error', fn: (error: Error) => void): this;
  on(event: 'clear', fn: () => void): this;
  off(event: TopazEvent, fn: Function): this;

  connect(existingPort?: SerialPort): Promise<void>;
  disconnect(): Promise<void>;
  clear(): void;

  toSVG(opts?: RenderOptions): string;
  toCanvas(opts?: RenderOptions): HTMLCanvasElement;
  toPNG(opts?: RenderOptions): Promise<Blob>;
  toSigString(): string;
}
