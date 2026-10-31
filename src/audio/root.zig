//! Plays sound: effects decoded into memory, music streamed as it plays,
//! and sound an app generates itself, mixed in Zig and sent to the system's
//! audio output.
//!
//! ```zig
//! const engine = try audio.Engine.init(allocator, .{ .app = app });
//! defer engine.deinit();
//! const click = try engine.decodeSound(click_wav); // decoded once
//! defer click.release();
//! _ = try engine.play(click); // as often as it sounds, over itself
//! const music = try engine.openStreamFile(file); // decoded as it plays
//! music.setLoop(true);
//! music.play();
//! ```
//!
//! WAV, FLAC, Ogg Vorbis and MP3 decode out of the box; other formats join through
//! `Options.formats`. The output opens when something first plays and
//! closes a few seconds after everything stopped. Where no output opens,
//! players still play on time, unheard, and `Engine.outputError` says why.
//! The engine owns two threads, one mixing into the output and one decoding
//! streams ahead; decoders run on the latter. Callbacks for players ending
//! and the output changing reach the App's main thread through `App.post`.
const std = @import("std");

pub const decoder = @import("decoder.zig");
pub const wav = @import("wav.zig");
pub const flac = @import("flac.zig");
pub const compressed = @import("compressed.zig");
const engine = @import("engine.zig");
const output = @import("output.zig");

pub const Error = decoder.Error;
pub const Input = decoder.Input;
pub const BytesInput = decoder.BytesInput;
pub const FileInput = decoder.FileInput;
pub const Decoder = decoder.Decoder;
pub const Format = decoder.Format;
pub const openDecoder = decoder.open;
pub const Sound = @import("sound.zig").Sound;

pub const Engine = engine.Engine;
pub const Options = engine.Options;
pub const Latency = engine.Latency;
pub const Output = engine.Output;
pub const Player = engine.Player;
pub const EndedCallback = engine.EndedCallback;
pub const OutputCallback = engine.OutputCallback;
pub const default_formats = engine.default_formats;

pub const OpenError = output.OpenError;
pub const WriteError = output.WriteError;
pub const Device = output.Device;
pub const Opener = output.Opener;
pub const Detail = output.Detail;
pub const Clock = output.Clock;
pub const sample_rate = output.sample_rate;
pub const channels = output.channels;
pub const period_frames = output.period_frames;

test {
    std.testing.refAllDecls(@This());
    _ = decoder;
    _ = wav;
    _ = flac;
    _ = compressed;
    _ = @import("sound.zig");
    _ = output;
    _ = @import("tests.zig");
}
