import ArgumentParser
import MarkupGrammar

struct GuideCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide",
        abstract: "Print the rules for marking clips in transcript.md (written for people and AIs)."
    )

    func run() { print(AnnotationGuide.text) }
}
