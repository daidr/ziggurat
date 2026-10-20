//! Texts of the update window in the languages the module ships, merged with
//! application overrides. Formats name their arguments in braces, such as
//! `{app}`, so a translation can order them as its grammar needs.
const std = @import("std");

/// One language. Empty fields fall back to the shipped language, then to
/// English. Placeholders: `{app}` application name, `{version}` the new
/// version, `{current}` the running one, `{downloaded}` and `{total}` sizes.
pub const Strings = struct {
    title: []const u8 = "",
    /// Label of a "Check for Updates" menu item.
    menu_item: []const u8 = "",
    checking: []const u8 = "",
    cancel: []const u8 = "",
    ok: []const u8 = "",
    up_to_date: []const u8 = "",
    /// {app} {current}
    up_to_date_message: []const u8 = "",
    unavailable: []const u8 = "",
    /// {app}
    unavailable_message: []const u8 = "",
    failed: []const u8 = "",
    check_failed: []const u8 = "",
    install_failed: []const u8 = "",
    /// {app}
    available: []const u8 = "",
    /// {app} {version} {current}
    available_message: []const u8 = "",
    release_notes: []const u8 = "",
    automatic_downloads: []const u8 = "",
    skip: []const u8 = "",
    remind_later: []const u8 = "",
    install: []const u8 = "",
    downloading: []const u8 = "",
    /// {downloaded} {total}
    progress: []const u8 = "",
    installing: []const u8 = "",
    ready: []const u8 = "",
    /// {app} {version}
    ready_message: []const u8 = "",
    later: []const u8 = "",
    relaunch: []const u8 = "",
    /// Decimal separator of sizes, such as "," in German.
    decimal: []const u8 = "",

    /// Fills empty fields from `fallback`.
    pub fn merge(self: Strings, fallback: Strings) Strings {
        var result = self;
        inline for (std.meta.fields(Strings)) |field| {
            if (@field(result, field.name).len == 0) @field(result, field.name) = @field(fallback, field.name);
        }
        return result;
    }
};

pub const Language = struct { tag: []const u8, strings: Strings };

pub const english: Strings = .{
    .title = "Software Update",
    .menu_item = "Check for Updates…",
    .checking = "Checking for updates…",
    .cancel = "Cancel",
    .ok = "OK",
    .up_to_date = "You’re up to date",
    .up_to_date_message = "{app} {current} is the newest version available.",
    .unavailable = "Updates unavailable",
    .unavailable_message = "{app} cannot update itself from where it is installed. Update it the way it was installed.",
    .failed = "Update failed",
    .check_failed = "Checking for updates did not succeed.",
    .install_failed = "The update could not be downloaded or installed.",
    .available = "A new version of {app} is available",
    .available_message = "{app} {version} is available. You have {current}.",
    .release_notes = "Release notes",
    .automatic_downloads = "Install updates automatically from now on",
    .skip = "Skip This Version",
    .remind_later = "Remind Me Later",
    .install = "Install Update",
    .downloading = "Downloading update…",
    .progress = "{downloaded} of {total}",
    .installing = "Installing update…",
    .ready = "Ready to restart",
    .ready_message = "{app} {version} is installed. It runs the next time {app} starts.",
    .later = "Later",
    .relaunch = "Restart Now",
    .decimal = ".",
};

/// Shipped languages by BCP 47 tag.
pub const languages = [_]Language{
    .{ .tag = "en", .strings = english },
    .{ .tag = "zh-Hans", .strings = .{
        .title = "软件更新",
        .menu_item = "检查更新…",
        .checking = "正在检查更新…",
        .cancel = "取消",
        .ok = "好",
        .up_to_date = "已是最新版本",
        .up_to_date_message = "{app} {current} 是目前的最新版本。",
        .unavailable = "无法更新",
        .unavailable_message = "{app} 无法在当前安装位置自行更新，请通过原来的安装方式更新。",
        .failed = "更新失败",
        .check_failed = "检查更新没有成功。",
        .install_failed = "无法下载或安装更新。",
        .available = "{app} 有新版本可用",
        .available_message = "{app} {version} 已发布，你当前使用的是 {current}。",
        .release_notes = "更新说明",
        .automatic_downloads = "以后自动安装更新",
        .skip = "跳过此版本",
        .remind_later = "稍后提醒",
        .install = "安装更新",
        .downloading = "正在下载更新…",
        .progress = "{downloaded} / {total}",
        .installing = "正在安装更新…",
        .ready = "可以重新启动",
        .ready_message = "{app} {version} 已安装，下次启动 {app} 时生效。",
        .later = "稍后",
        .relaunch = "立即重新启动",
    } },
    .{ .tag = "zh-Hant", .strings = .{
        .title = "軟體更新",
        .menu_item = "檢查更新…",
        .checking = "正在檢查更新…",
        .cancel = "取消",
        .ok = "好",
        .up_to_date = "已是最新版本",
        .up_to_date_message = "{app} {current} 是目前的最新版本。",
        .unavailable = "無法更新",
        .unavailable_message = "{app} 無法在目前的安裝位置自行更新，請透過原本的安裝方式更新。",
        .failed = "更新失敗",
        .check_failed = "檢查更新沒有成功。",
        .install_failed = "無法下載或安裝更新。",
        .available = "{app} 有新版本可用",
        .available_message = "{app} {version} 已推出，你目前使用的是 {current}。",
        .release_notes = "更新說明",
        .automatic_downloads = "之後自動安裝更新",
        .skip = "略過此版本",
        .remind_later = "稍後提醒",
        .install = "安裝更新",
        .downloading = "正在下載更新…",
        .progress = "{downloaded} / {total}",
        .installing = "正在安裝更新…",
        .ready = "可以重新啟動",
        .ready_message = "{app} {version} 已安裝，下次啟動 {app} 時生效。",
        .later = "稍後",
        .relaunch = "立即重新啟動",
    } },
    .{ .tag = "ja", .strings = .{
        .title = "ソフトウェア・アップデート",
        .menu_item = "アップデートを確認…",
        .checking = "アップデートを確認しています…",
        .cancel = "キャンセル",
        .ok = "OK",
        .up_to_date = "最新の状態です",
        .up_to_date_message = "{app} {current} は利用できる最新のバージョンです。",
        .unavailable = "アップデートできません",
        .unavailable_message = "{app} はインストールされている場所から自身をアップデートできません。インストールした方法でアップデートしてください。",
        .failed = "アップデートに失敗しました",
        .check_failed = "アップデートを確認できませんでした。",
        .install_failed = "アップデートをダウンロードまたはインストールできませんでした。",
        .available = "{app} の新しいバージョンがあります",
        .available_message = "{app} {version} が利用できます。現在のバージョンは {current} です。",
        .release_notes = "リリースノート",
        .automatic_downloads = "今後はアップデートを自動的にインストール",
        .skip = "このバージョンをスキップ",
        .remind_later = "後で通知",
        .install = "アップデートをインストール",
        .downloading = "アップデートをダウンロードしています…",
        .progress = "{downloaded} / {total}",
        .installing = "アップデートをインストールしています…",
        .ready = "再起動の準備ができました",
        .ready_message = "{app} {version} がインストールされました。次回 {app} を起動したときに使われます。",
        .later = "後で",
        .relaunch = "今すぐ再起動",
    } },
    .{ .tag = "ko", .strings = .{
        .title = "소프트웨어 업데이트",
        .menu_item = "업데이트 확인…",
        .checking = "업데이트를 확인하는 중…",
        .cancel = "취소",
        .ok = "확인",
        .up_to_date = "최신 버전입니다",
        .up_to_date_message = "{app} {current}이(가) 사용 가능한 최신 버전입니다.",
        .unavailable = "업데이트할 수 없음",
        .unavailable_message = "{app}은(는) 설치된 위치에서 스스로 업데이트할 수 없습니다. 설치한 방법으로 업데이트하십시오.",
        .failed = "업데이트 실패",
        .check_failed = "업데이트를 확인하지 못했습니다.",
        .install_failed = "업데이트를 다운로드하거나 설치하지 못했습니다.",
        .available = "{app}의 새 버전이 있습니다",
        .available_message = "{app} {version}을(를) 사용할 수 있습니다. 현재 버전은 {current}입니다.",
        .release_notes = "릴리스 노트",
        .automatic_downloads = "앞으로 업데이트 자동 설치",
        .skip = "이 버전 건너뛰기",
        .remind_later = "나중에 알림",
        .install = "업데이트 설치",
        .downloading = "업데이트를 다운로드하는 중…",
        .progress = "{downloaded} / {total}",
        .installing = "업데이트를 설치하는 중…",
        .ready = "다시 시작 준비 완료",
        .ready_message = "{app} {version}이(가) 설치되었습니다. 다음에 {app}을(를) 시작할 때 적용됩니다.",
        .later = "나중에",
        .relaunch = "지금 다시 시작",
    } },
    .{ .tag = "de", .strings = .{
        .title = "Softwareaktualisierung",
        .menu_item = "Nach Updates suchen …",
        .checking = "Suche nach Updates …",
        .cancel = "Abbrechen",
        .ok = "OK",
        .up_to_date = "Alles aktuell",
        .up_to_date_message = "{app} {current} ist die neueste verfügbare Version.",
        .unavailable = "Updates nicht verfügbar",
        .unavailable_message = "{app} kann sich am Installationsort nicht selbst aktualisieren. Aktualisieren Sie es auf dem Weg, auf dem es installiert wurde.",
        .failed = "Update fehlgeschlagen",
        .check_failed = "Die Suche nach Updates ist fehlgeschlagen.",
        .install_failed = "Das Update konnte nicht geladen oder installiert werden.",
        .available = "Eine neue Version von {app} ist verfügbar",
        .available_message = "{app} {version} ist verfügbar. Installiert ist {current}.",
        .release_notes = "Versionshinweise",
        .automatic_downloads = "Updates künftig automatisch installieren",
        .skip = "Diese Version überspringen",
        .remind_later = "Später erinnern",
        .install = "Update installieren",
        .downloading = "Update wird geladen …",
        .progress = "{downloaded} von {total}",
        .installing = "Update wird installiert …",
        .ready = "Bereit zum Neustart",
        .ready_message = "{app} {version} ist installiert und wird beim nächsten Start von {app} verwendet.",
        .later = "Später",
        .relaunch = "Jetzt neu starten",
        .decimal = ",",
    } },
    .{ .tag = "fr", .strings = .{
        .title = "Mise à jour de logiciel",
        .menu_item = "Rechercher des mises à jour…",
        .checking = "Recherche de mises à jour…",
        .cancel = "Annuler",
        .ok = "OK",
        .up_to_date = "Vous êtes à jour",
        .up_to_date_message = "{app} {current} est la version la plus récente.",
        .unavailable = "Mises à jour indisponibles",
        .unavailable_message = "{app} ne peut pas se mettre à jour depuis son emplacement d’installation. Mettez-le à jour de la façon dont il a été installé.",
        .failed = "Échec de la mise à jour",
        .check_failed = "La recherche de mises à jour a échoué.",
        .install_failed = "La mise à jour n’a pas pu être téléchargée ou installée.",
        .available = "Une nouvelle version de {app} est disponible",
        .available_message = "{app} {version} est disponible. Vous avez la version {current}.",
        .release_notes = "Notes de version",
        .automatic_downloads = "Installer désormais les mises à jour automatiquement",
        .skip = "Ignorer cette version",
        .remind_later = "Me le rappeler plus tard",
        .install = "Installer la mise à jour",
        .downloading = "Téléchargement de la mise à jour…",
        .progress = "{downloaded} sur {total}",
        .installing = "Installation de la mise à jour…",
        .ready = "Prêt à redémarrer",
        .ready_message = "{app} {version} est installé et sera utilisé au prochain démarrage de {app}.",
        .later = "Plus tard",
        .relaunch = "Redémarrer maintenant",
        .decimal = ",",
    } },
    .{ .tag = "es", .strings = .{
        .title = "Actualización de software",
        .menu_item = "Buscar actualizaciones…",
        .checking = "Buscando actualizaciones…",
        .cancel = "Cancelar",
        .ok = "Aceptar",
        .up_to_date = "Está actualizado",
        .up_to_date_message = "{app} {current} es la versión más reciente.",
        .unavailable = "Actualizaciones no disponibles",
        .unavailable_message = "{app} no puede actualizarse desde donde está instalado. Actualícelo de la misma forma en que lo instaló.",
        .failed = "No se pudo actualizar",
        .check_failed = "No se pudo buscar actualizaciones.",
        .install_failed = "No se pudo descargar o instalar la actualización.",
        .available = "Hay una nueva versión de {app}",
        .available_message = "{app} {version} está disponible. Tiene la versión {current}.",
        .release_notes = "Notas de la versión",
        .automatic_downloads = "Instalar actualizaciones automáticamente a partir de ahora",
        .skip = "Omitir esta versión",
        .remind_later = "Recordármelo más tarde",
        .install = "Instalar actualización",
        .downloading = "Descargando actualización…",
        .progress = "{downloaded} de {total}",
        .installing = "Instalando actualización…",
        .ready = "Listo para reiniciar",
        .ready_message = "{app} {version} está instalado y se usará la próxima vez que se inicie {app}.",
        .later = "Más tarde",
        .relaunch = "Reiniciar ahora",
        .decimal = ",",
    } },
};

/// The shipped language closest to `locale`, such as "zh-TW" or "de_AT":
/// Chinese picks its script from the script or region, other languages
/// match on the primary subtag, and anything else is English.
pub fn shipped(locale: []const u8) Language {
    var primary_buffer: [8]u8 = undefined;
    const end = std.mem.indexOfAny(u8, locale, "-_.@") orelse locale.len;
    if (end == 0 or end > primary_buffer.len) return languages[0];
    const primary = std.ascii.lowerString(&primary_buffer, locale[0..end]);
    if (std.mem.eql(u8, primary, "zh")) {
        const rest = locale[end..];
        const traditional = containsIgnoreCase(rest, "hant") or containsIgnoreCase(rest, "tw") or containsIgnoreCase(rest, "hk") or containsIgnoreCase(rest, "mo");
        return find(if (traditional) "zh-Hant" else "zh-Hans").?;
    }
    return find(primary) orelse languages[0];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

pub fn find(tag: []const u8) ?Language {
    for (languages) |language| if (std.ascii.eqlIgnoreCase(language.tag, tag)) return language;
    return null;
}

/// The strings for `locale`: application overrides for the exact or primary
/// tag first, then the shipped language, then English.
pub fn resolve(locale: []const u8, overrides: []const Language) Strings {
    const base = shipped(locale);
    var result = base.strings.merge(english);
    const end = std.mem.indexOfAny(u8, locale, "-_.@") orelse locale.len;
    for (overrides) |language| {
        const matches = std.ascii.eqlIgnoreCase(language.tag, locale) or std.ascii.eqlIgnoreCase(language.tag, base.tag) or std.ascii.eqlIgnoreCase(language.tag, locale[0..end]);
        if (matches) result = language.strings.merge(result);
    }
    return result;
}

pub const Argument = struct { name: []const u8, value: []const u8 };

/// Writes `format` with each `{name}` replaced. Unknown names and a lone
/// brace stay as they are.
pub fn render(writer: *std.Io.Writer, format: []const u8, arguments: []const Argument) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < format.len) {
        if (format[index] == '{') {
            if (std.mem.indexOfScalarPos(u8, format, index, '}')) |close| {
                if (lookup(arguments, format[index + 1 .. close])) |value| {
                    try writer.writeAll(value);
                    index = close + 1;
                    continue;
                }
            }
        }
        try writer.writeByte(format[index]);
        index += 1;
    }
}

fn lookup(arguments: []const Argument, name: []const u8) ?[]const u8 {
    for (arguments) |argument| if (std.mem.eql(u8, argument.name, name)) return argument.value;
    return null;
}

/// A byte count in megabytes with one decimal, such as "12.3 MB".
pub fn megabytes(destination: []u8, bytes: u64, decimal: []const u8) ![]const u8 {
    const tenths = (bytes * 10 + 524_288) / 1_048_576;
    return std.fmt.bufPrint(destination, "{d}{s}{d} MB", .{ tenths / 10, decimal, tenths % 10 });
}

const testing = std.testing;

test "every shipped language fills every field and keeps the placeholders" {
    inline for (std.meta.fields(Strings)) |field| try testing.expect(@field(english, field.name).len > 0);
    for (languages) |language| {
        const strings = language.strings.merge(english);
        inline for (std.meta.fields(Strings)) |field| {
            const text = @field(strings, field.name);
            const reference = @field(english, field.name);
            try testing.expect(std.unicode.utf8ValidateSlice(text));
            for ([_][]const u8{ "{app}", "{version}", "{current}", "{downloaded}", "{total}" }) |placeholder| {
                if (std.mem.indexOf(u8, reference, placeholder) != null) try testing.expect(std.mem.indexOf(u8, text, placeholder) != null);
            }
        }
    }
}

test "locales pick the closest shipped language" {
    try testing.expectEqualStrings("zh-Hans", shipped("zh-CN").tag);
    try testing.expectEqualStrings("zh-Hans", shipped("zh_CN.UTF-8").tag);
    try testing.expectEqualStrings("zh-Hant", shipped("zh-TW").tag);
    try testing.expectEqualStrings("zh-Hant", shipped("zh-Hant-HK").tag);
    try testing.expectEqualStrings("de", shipped("de_AT").tag);
    try testing.expectEqualStrings("en", shipped("sv-SE").tag);
    try testing.expectEqualStrings("en", shipped("").tag);
    try testing.expectEqualStrings("en", shipped("C").tag);
}

test "overrides change texts and add languages" {
    const overrides = [_]Language{
        .{ .tag = "en", .strings = .{ .install = "Update Now" } },
        .{ .tag = "sv", .strings = .{ .title = "Programuppdatering" } },
    };
    const english_result = resolve("en-GB", &overrides);
    try testing.expectEqualStrings("Update Now", english_result.install);
    try testing.expectEqualStrings("Software Update", english_result.title);
    const swedish = resolve("sv-SE", &overrides);
    try testing.expectEqualStrings("Programuppdatering", swedish.title);
    try testing.expectEqualStrings("Cancel", swedish.cancel);
    try testing.expectEqualStrings("取消", resolve("zh-CN", &overrides).cancel);
}

test "formats replace named arguments in any order" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try render(&writer, "{version} for {app} {unknown} {", &.{ .{ .name = "app", .value = "Notes" }, .{ .name = "version", .value = "2.0" } });
    try testing.expectEqualStrings("2.0 for Notes {unknown} {", writer.buffered());
    try testing.expectEqualStrings("12.3 MB", try megabytes(&buffer, 12_900_000, "."));
    try testing.expectEqualStrings("0,0 MB", try megabytes(&buffer, 10, ","));
}
