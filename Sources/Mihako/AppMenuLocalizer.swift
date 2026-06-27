import AppKit

@MainActor
enum AppMenuLocalizer {
    static func apply() {
        guard let mainMenu = NSApp.mainMenu else {
            return
        }

        let appName = NSRunningApplication.current.localizedName
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Mihako"

        localize(menu: mainMenu, appName: appName)
    }

    private static func localize(menu: NSMenu, appName: String) {
        for item in menu.items {
            if let key = localizationKey(for: item.title, appName: appName) {
                item.title = localizedTitle(for: key, appName: appName)
            }

            if let submenu = item.submenu {
                if let key = localizationKey(for: submenu.title, appName: appName) {
                    submenu.title = localizedTitle(for: key, appName: appName)
                }

                localize(menu: submenu, appName: appName)
            }
        }
    }

    private static func localizationKey(for title: String, appName: String) -> String? {
        let normalizedTitle = title
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalizedTitle == "About \(appName)" || normalizedTitle == "\(appName)について" || normalizedTitle == "\(appName) について" {
            return "menu.aboutApp"
        }

        if normalizedTitle == "Hide \(appName)" || normalizedTitle == "\(appName)を隠す" || normalizedTitle == "\(appName) を隠す" {
            return "menu.hideApp"
        }

        if normalizedTitle == "Quit \(appName)" || normalizedTitle == "\(appName)を終了" || normalizedTitle == "\(appName) を終了" {
            return "menu.quitApp"
        }

        if normalizedTitle == "\(appName) Help" || normalizedTitle == "\(appName)ヘルプ" || normalizedTitle == "\(appName) ヘルプ" {
            return "menu.appHelp"
        }

        return staticMenuTitleKeys[normalizedTitle]
    }

    private static func localizedTitle(for key: String, appName: String) -> String {
        switch key {
        case "menu.aboutApp", "menu.hideApp", "menu.quitApp", "menu.appHelp":
            return L10n.format(key, appName)
        default:
            return L10n.string(key)
        }
    }

    private static let staticMenuTitleKeys: [String: String] = [
        "File": "menu.file",
        "ファイル": "menu.file",
        "Edit": "menu.edit",
        "編集": "menu.edit",
        "View": "menu.view",
        "表示": "menu.view",
        "Window": "menu.window",
        "ウィンドウ": "menu.window",
        "Help": "menu.help",
        "ヘルプ": "menu.help",

        "Settings...": "menu.settings",
        "設定...": "menu.settings",
        "Services": "menu.services",
        "サービス": "menu.services",
        "Hide Others": "menu.hideOthers",
        "ほかを隠す": "menu.hideOthers",
        "Show All": "menu.showAll",
        "すべて表示": "menu.showAll",

        "External Tools...": "External Tools...",
        "外部ツール...": "External Tools...",
        "Launcher Folders...": "Launcher Folders...",
        "ランチャーフォルダー...": "Launcher Folders...",
        "Language": "Language",
        "言語": "Language",
        "Appearance": "Appearance",
        "外観": "Appearance",
        "Use System Language": "Use System Language",
        "システム設定に従う": "Use System Language",
        "English": "English",
        "英語": "English",
        "Japanese": "Japanese",
        "日本語": "Japanese",
        "Use System Appearance": "Use System Appearance",
        "システムの外観に従う": "Use System Appearance",
        "Light": "Light",
        "ライト": "Light",
        "Dark": "Dark",
        "ダーク": "Dark",

        "New Window": "New Window",
        "新規ウィンドウ": "New Window",
        "New Window (Desktop)": "New Window (Desktop)",
        "新規ウィンドウ（デスクトップ）": "New Window (Desktop)",
        "New Window (Downloads)": "New Window (Downloads)",
        "新規ウィンドウ（ダウンロード）": "New Window (Downloads)",
        "New Folder": "New Folder",
        "新規フォルダ": "New Folder",
        "Open": "Open",
        "開く": "Open",
        "Rename": "Rename",
        "名前変更": "Rename",
        "Move to Trash": "Move to Trash",
        "ゴミ箱に移動": "Move to Trash",
        "Cut": "Cut",
        "切り取り": "Cut",
        "Copy": "Copy",
        "コピー": "Copy",
        "Paste": "Paste",
        "貼り付け": "Paste",
        "Select All": "Select All",
        "すべて選択": "Select All",

        "Undo": "menu.undo",
        "取り消す": "menu.undo",
        "Redo": "menu.redo",
        "やり直す": "menu.redo",
        "Close": "menu.close",
        "閉じる": "menu.close",
        "Close Window": "menu.closeWindow",
        "ウィンドウを閉じる": "menu.closeWindow",
        "Minimize": "menu.minimize",
        "しまう": "menu.minimize",
        "Zoom": "menu.zoom",
        "拡大／縮小": "menu.zoom",
        "Bring All to Front": "menu.bringAllToFront",
        "すべてを手前に移動": "menu.bringAllToFront",
        "Enter Full Screen": "menu.enterFullScreen",
        "フルスクリーンにする": "menu.enterFullScreen",
        "Exit Full Screen": "menu.exitFullScreen",
        "フルスクリーンを解除": "menu.exitFullScreen",

        "Find": "menu.find",
        "検索": "menu.find",
        "Find...": "menu.findEllipsis",
        "検索...": "menu.findEllipsis",
        "Find Next": "menu.findNext",
        "次を検索": "menu.findNext",
        "Find Previous": "menu.findPrevious",
        "前を検索": "menu.findPrevious",
        "Use Selection for Find": "menu.useSelectionForFind",
        "選択部分を検索に使用": "menu.useSelectionForFind",
        "Jump to Selection": "menu.jumpToSelection",
        "選択部分へジャンプ": "menu.jumpToSelection",

        "Spelling and Grammar": "menu.spellingAndGrammar",
        "スペルと文法": "menu.spellingAndGrammar",
        "Show Spelling and Grammar": "menu.showSpellingAndGrammar",
        "スペルと文法を表示": "menu.showSpellingAndGrammar",
        "Check Document Now": "menu.checkDocumentNow",
        "書類を今すぐチェック": "menu.checkDocumentNow",
        "Check Spelling While Typing": "menu.checkSpellingWhileTyping",
        "入力中にスペルチェック": "menu.checkSpellingWhileTyping",
        "Check Grammar With Spelling": "menu.checkGrammarWithSpelling",
        "スペルと一緒に文法をチェック": "menu.checkGrammarWithSpelling",
        "Correct Spelling Automatically": "menu.correctSpellingAutomatically",
        "スペルを自動的に修正": "menu.correctSpellingAutomatically",

        "Substitutions": "menu.substitutions",
        "置換": "menu.substitutions",
        "Show Substitutions": "menu.showSubstitutions",
        "置換を表示": "menu.showSubstitutions",
        "Smart Copy/Paste": "menu.smartCopyPaste",
        "スマートコピー／ペースト": "menu.smartCopyPaste",
        "Smart Quotes": "menu.smartQuotes",
        "スマート引用符": "menu.smartQuotes",
        "Smart Dashes": "menu.smartDashes",
        "スマートダッシュ": "menu.smartDashes",
        "Smart Links": "menu.smartLinks",
        "スマートリンク": "menu.smartLinks",
        "Data Detectors": "menu.dataDetectors",
        "データ検出": "menu.dataDetectors",
        "Text Replacement": "menu.textReplacement",
        "テキストの置換": "menu.textReplacement",

        "Transformations": "menu.transformations",
        "変換": "menu.transformations",
        "Make Upper Case": "menu.makeUpperCase",
        "大文字にする": "menu.makeUpperCase",
        "Make Lower Case": "menu.makeLowerCase",
        "小文字にする": "menu.makeLowerCase",
        "Capitalize": "menu.capitalize",
        "語頭を大文字にする": "menu.capitalize",

        "Speech": "menu.speech",
        "スピーチ": "menu.speech",
        "Start Speaking": "menu.startSpeaking",
        "読み上げを開始": "menu.startSpeaking",
        "Stop Speaking": "menu.stopSpeaking",
        "読み上げを停止": "menu.stopSpeaking",
        "Start Dictation...": "menu.startDictation",
        "音声入力を開始...": "menu.startDictation",
        "Emoji & Symbols": "menu.emojiAndSymbols",
        "絵文字と記号": "menu.emojiAndSymbols"
    ]
}
