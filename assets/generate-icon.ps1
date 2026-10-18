[CmdletBinding()]
param([string]$OutputPath = (Join-Path $PSScriptRoot 'application.ico'))
$ErrorActionPreference = 'Stop'
if (-not ('ZigguratIconWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
public static class ZigguratIconWriter {
    static bool Inside(double x, double y, double left, double top, double right, double bottom) {
        return x >= left && x < right && y >= top && y < bottom;
    }
    static int Pixel(double x, double y) {
        if (!Inside(x, y, 13, 13, 243, 243)) return 0;
        double dx = Math.Max(45 - x, Math.Max(x - 211, 0));
        double dy = Math.Max(45 - y, Math.Max(y - 211, 0));
        if (dx * dx + dy * dy > 32 * 32) return 0;
        bool gold = Inside(x,y,56,166,200,200) || Inside(x,y,77,125,179,163) ||
            Inside(x,y,102,77,154,122) || Inside(x,y,120,51,136,74);
        if (Inside(x,y,119,174,137,200)) gold = false;
        return gold ? 0xefc76d : 0x142d3e;
    }
    static void BigEndian(Stream stream, uint value) {
        stream.WriteByte((byte)(value >> 24)); stream.WriteByte((byte)(value >> 16));
        stream.WriteByte((byte)(value >> 8)); stream.WriteByte((byte)value);
    }
    static void Chunk(Stream stream, string kind, byte[] payload) {
        byte[] name = Encoding.ASCII.GetBytes(kind);
        BigEndian(stream, (uint)payload.Length); stream.Write(name); stream.Write(payload);
        uint crc = 0xffffffff;
        foreach (byte value in name) crc = Crc(crc, value);
        foreach (byte value in payload) crc = Crc(crc, value);
        BigEndian(stream, crc ^ 0xffffffff);
    }
    static uint Crc(uint crc, byte value) {
        crc ^= value;
        for (int bit=0; bit<8; bit++) crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
        return crc;
    }
    static byte[] Image(int size) {
        using (var scanlines = new MemoryStream()) {
            for (int y=0; y<size; y++) {
                scanlines.WriteByte(0);
                for (int x=0; x<size; x++) {
                    int red=0, green=0, blue=0, covered=0;
                    for (int sy=0;sy<4;sy++) for (int sx=0;sx<4;sx++) {
                        int rgb = Pixel((x+(sx+0.5)/4)*256/size, (y+(sy+0.5)/4)*256/size);
                        if (rgb != 0) { covered++; red += rgb >> 16; green += (rgb >> 8) & 255; blue += rgb & 255; }
                    }
                    scanlines.WriteByte((byte)(covered == 0 ? 0 : red/covered));
                    scanlines.WriteByte((byte)(covered == 0 ? 0 : green/covered));
                    scanlines.WriteByte((byte)(covered == 0 ? 0 : blue/covered)); scanlines.WriteByte((byte)(covered*255/16));
                }
            }
            using (var png = new MemoryStream()) {
                png.Write(new byte[]{137,80,78,71,13,10,26,10});
                using (var header = new MemoryStream()) {
                    BigEndian(header, (uint)size); BigEndian(header, (uint)size);
                    header.Write(new byte[]{8,6,0,0,0}); Chunk(png, "IHDR", header.ToArray());
                }
                using (var compressed = new MemoryStream()) {
                    using (var zlib = new ZLibStream(compressed, CompressionLevel.SmallestSize, true)) scanlines.WriteTo(zlib);
                    Chunk(png, "IDAT", compressed.ToArray());
                }
                Chunk(png, "IEND", Array.Empty<byte>());
                return png.ToArray();
            }
        }
    }
    public static void Write(string filename) {
        int[] sizes = {16,20,24,32,40,48,64,128,256};
        using (var output = new BinaryWriter(File.Create(filename))) {
            output.Write((ushort)0); output.Write((ushort)1); output.Write((ushort)sizes.Length);
            byte[][] images = new byte[sizes.Length][];
            for (int i=0; i<sizes.Length; i++) images[i] = Image(sizes[i]);
            uint offset = (uint)(6 + sizes.Length * 16);
            for (int i=0; i<sizes.Length; i++) {
                int size = sizes[i];
                uint bytes = (uint)images[i].Length;
                output.Write((byte)(size == 256 ? 0 : size)); output.Write((byte)(size == 256 ? 0 : size));
                output.Write((byte)0); output.Write((byte)0); output.Write((ushort)1); output.Write((ushort)32);
                output.Write(bytes); output.Write(offset); offset += bytes;
            }
            foreach (byte[] image in images) output.Write(image);
        }
    }
}
'@
}
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
[ZigguratIconWriter]::Write($resolvedOutput)
Get-Item -LiteralPath $resolvedOutput
