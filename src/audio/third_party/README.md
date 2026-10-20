# 第三方解码器

这里的文件按固定提交原样复制，不做修改。升级时替换文件、更新下表，并同步 `src/audio/compressed.zig` 里的哈希测试。

| 文件 | 来源 | 提交 | SHA-256 | 许可证 |
| --- | --- | --- | --- | --- |
| `minimp3.h` | https://github.com/lieff/minimp3 | `afb604c06bc8beb145fecd42c0ceb5bda8795144` | `5fb296a790734772b65a5514438cc06d14f24e539c13475ff2a7f737681c82c0` | CC0 1.0（公有领域） |
| `minimp3_ex.h` | https://github.com/lieff/minimp3 | `afb604c06bc8beb145fecd42c0ceb5bda8795144` | `bb001301b8666ea7a45ae057b62b17074483213b0d410555d97cc4d076e110df` | CC0 1.0（公有领域） |
| `stb_vorbis.c` | https://github.com/nothings/stb | `f58f558c120e9b32c217290b80bad1a0729fbb2c` | `4c7cb2ff1f7011e9d67950446b7eb9ca044f2e464d76bfbb0b84dd2e23e65636` | MIT 或 Unlicense（公有领域），二选一；许可证全文在文件末尾 |

两者都不要求在分发物中署名。`src/audio/mp3.c` 与 `src/audio/vorbis.c` 是本项目的胶水层，构建时以 `-std=c99 -w -fno-sanitize=undefined` 编译：上游代码的告警与未定义行为检查不由本项目负责。
