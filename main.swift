import Cocoa
import Translation

let app = NSApplication.shared
let lexicon = try Lexicon(Bundle.main.resourceURL!)
if CommandLine.arguments.contains("--verify") {
    let cases = [("Test apple 🍊",7,"apple"),("Test apple 🍊",12,"🍊"),("👩🏽‍💻",4,"👩🏽‍💻"),("co-worker",3,"co-worker"),("rock’s",3,"rock’s")]
    for (sample,offset,expected) in cases { precondition(lexicon.token(sample,at:offset) == expected) }
    precondition(lexicon.token("one two",at:3) == nil)
    precondition(lexicon.token("“🍊”",at:0) == nil && lexicon.token("“🍊”",at:3) == nil)
    precondition(lexicon.token("“🍊”",at:1) == "🍊")
    precondition(lexicon.meaning("APPLE")?.contains("苹果") == true && lexicon.meaning("🍊") == "橘子")
    precondition(lexicon.meaning("👩🏽‍💻") != nil && lexicon.meaning("🇨🇳") != nil)
    print("PASS: word meanings, UTF-16 hover offsets, whitespace, compound words, emoji sequences")
    Task {
        let status = await LanguageAvailability().status(from:english,to:chinese)
        if status == .installed {
            do { let result = try await TranslationSession(installedSource:english,target:chinese).translate("I like oranges."); print("Sentence translation:",result.targetText); exit(result.targetText.isEmpty ? 1 : 0) }
            catch { print("Translation error:",error.localizedDescription); exit(1) }
        } else { print(status == .supported ? "Language pack: download required" : "Language pair unavailable"); exit(0) }
    }
    app.run()
} else {
    app.setActivationPolicy(.accessory)
    MainActor.assumeIsolated {
        let delegate = Agent(lexicon); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
