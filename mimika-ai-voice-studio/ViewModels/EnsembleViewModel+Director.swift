//
//  EnsembleViewModel+Director.swift
//  mimika-ai-voice-studio
//
//  Phase 6 — director turn mode + the agreement-collapse "grenade". The director
//  asks the LLM who speaks next (mention override still wins; weighted-random on
//  any failure, so a slow/bad director never stalls the loop). The grenade
//  detector spots a conversation that's collapsed into consensus and lets the
//  user arm a one-shot disruption.
//

import Foundation

extension EnsembleViewModel {

    // MARK: - Director turn mode

    /// Pick the next speaker via an LLM "director" call. Mention override wins
    /// first (free + deterministic); on any failure we fall back to weighted-
    /// random excluding the last speaker.
    func pickNextViaDirector(lastSpeaker: UUID?) async -> UUID? {
        if let last = turns.last,
           let mentioned = Conductor.detectMention(in: last.content, cast: cast, excluding: last.speakerID),
           !Conductor.wouldExtendMentionPingPong(mentioned: mentioned, cast: cast, turns: turns) {
            return mentioned
        }
        let prompt = DirectorPrompt.build(cast: cast, turns: turnsForModel(), window: verbatimWindow)
        do {
            var raw = ""
            let stream = makeClient().streamChat(
                messages: [ChatMessage(role: .user, content: prompt.user)],
                model: resolvedModel, systemPrompt: prompt.system, temperature: 0.3, maxTokens: 16
            )
            for try await delta in stream { raw += delta }
            if let picked = DirectorPrompt.resolve(raw, cast: cast, excluding: lastSpeaker) {
                return picked
            }
        } catch {
            // fall through to weighted-random
        }
        var generator = SystemRandomNumberGenerator()
        let pool = cast.filter { $0.id != lastSpeaker }
        return Conductor.weightedChoice(pool.isEmpty ? cast : pool, using: &generator)?.id
    }

    // MARK: - Agreement-collapse "grenade"

    /// True when the recent cast turns have collapsed into consensus (lots of
    /// agreement, no pushback) — the cue to offer a disruption.
    var agreementCollapsed: Bool {
        Self.detectsAgreementCollapse(turns: turns)
    }

    /// Arm a one-shot disruption: the next speaker is told to break the
    /// consensus. Kicks a turn if the loop is parked so it happens now.
    func throwGrenade() {
        pendingGrenade = true
        kickIfParked()
    }

    /// Pure detector (static, for testing): the last few CAST turns signal
    /// agreement and none signal disagreement.
    static func detectsAgreementCollapse(turns: [EnsembleTurn]) -> Bool {
        let recent = turns.suffix(5).filter { $0.speakerID != nil }
        guard recent.count >= 3 else { return false }
        let agree = ["agree", "exactly", "well said", "good point", "couldn't agree",
                     "same here", "absolutely", "indeed", "so true", "definitely",
                     "you're right", "fair point", "no notes"]
        let disagree = ["but ", "however", "disagree", "not sure", "actually", "on the contrary",
                        "i doubt", "that's wrong", "hardly", "no, ", "i'd push back", "nonsense"]
        var agreeCount = 0
        for turn in recent {
            let t = turn.content.lowercased()
            if disagree.contains(where: { t.contains($0) }) { return false }   // any pushback → not collapsed
            if agree.contains(where: { t.contains($0) }) { agreeCount += 1 }
        }
        return agreeCount >= 2
    }
}
