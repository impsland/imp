import Foundation
import Testing
@testable import ImpKit

/// Settings exactly as Imp 1.0.5 saved them (encoded by that version's own code). A blob that
/// doesn't decode is a fresh start (`PreferencesStore.load`), so this must keep loading.
@Suite struct UpgradeFrom105Tests {
    static let saved = #"""
{
 "ai": {
  "brain": {
   "model": "openai/gpt-x",
   "service": "58C1A5B2-97DF-4564-80E8-3AB77F60AA0C"
  },
  "services": [
   {
    "baseURL": "https://openrouter.ai/api/v1",
    "id": "58C1A5B2-97DF-4564-80E8-3AB77F60AA0C",
    "name": "OpenRouter"
   },
   {
    "baseURL": "http://localhost:11434/v1",
    "id": "27CA1130-8D50-4309-8B06-1198E4C373CF",
    "name": "Ollama"
   }
  ]
 },
 "animations": [
  "smile",
  {
   "isEnabled": false,
   "triggers": [
    "idle"
   ]
  },
  "dizzy",
  {
   "isEnabled": true,
   "triggers": [
    "circle"
   ]
  }
 ],
 "antics": false,
 "appearance": "dark",
 "bubbleAutoHideSeconds": 60,
 "click": "talk",
 "dictationLocale": "en_GB",
 "doubleClickOpensSettings": false,
 "imps": [
  {
   "favoriteHue": 0,
   "hue": 0,
   "id": "1A1A1A1A-0000-4000-8000-00000000F00D",
   "isActive": false,
   "knowsFavorite": false,
   "name": "Imp",
   "personality": "You are Imp, a tiny, witty desk imp living on the user's Mac. Be genuinely helpful and brief: one to three sentences unless asked for more, with a light touch of mischief. Reply in the language the user speaks, in plain sentences: no markdown, lists, emoji or code unless asked. When the user wants something done on their Mac, do it with your tools rather than explaining how.",
   "scale": 1,
   "servers": [],
   "usesShell": true
  },
  {
   "brain": {
    "model": "llama3",
    "service": "27CA1130-8D50-4309-8B06-1198E4C373CF"
   },
   "favoriteHue": 0.6,
   "hue": 0.3,
   "id": "1986C39A-804D-41D6-A882-E24271A803EB",
   "instructions": "custom",
   "isActive": true,
   "knowsFavorite": false,
   "name": "Pip",
   "origin": [
    10,
    20
   ],
   "personality": "You are Pip.",
   "scale": 1,
   "servers": [
    "1C607DD2-D56B-44FC-B9F5-DB0604457296"
   ],
   "usesShell": true
  }
 ],
 "mcpServers": [
  {
   "arguments": [
    "-y",
    "@dtst/img"
   ],
   "command": "npx",
   "environment": {
    "OPENAI_MODEL": "m"
   },
   "headers": {},
   "id": "1C607DD2-D56B-44FC-B9F5-DB0604457296",
   "isEnabled": true,
   "name": "img",
   "transport": "stdio",
   "url": ""
  }
 ],
 "mouseGames": false,
 "shortcuts": [
  {
   "clipboard": true,
   "hotkey": {
    "keyCode": 17,
    "modifiers": 4352
   },
   "id": "B7A5BE93-6B4D-4F56-9C8A-9DEAA2FA5C0B",
   "isEnabled": true,
   "name": "Translate",
   "performer": "1986C39A-804D-41D6-A882-E24271A803EB",
   "prompt": "Translate"
  }
 ]
}
"""#

    private func load() throws -> ImpPreferences {
        var p = try JSONDecoder().decode(ImpPreferences.self, from: Data(Self.saved.utf8))
        p.upgrade()
        return p
    }

    @Test func everythingCarriesOver() throws {
        let p = try load()
        #expect(p.ai.services.map(\.name) == ["OpenRouter", "Ollama"])
        #expect(p.appearance == .dark && !p.antics && p.bubbleAutoHideSeconds == 60 && p.dictationLocale == "en_GB")
        #expect(p.mcpServers.first?.environment == ["OPENAI_MODEL": "m"])
        #expect(p.imps.map(\.name) == ["Imp", "Pip"])
        #expect(p.imps[1].instructions == "custom" && p.imps[1].origin == CGPoint(x: 10, y: 20))
        #expect(!p.keysInKeychain)
    }

    @Test func modelsBelongToServicesNow() throws {
        let p = try load()
        #expect(p.ai.services.map(\.model) == ["openai/gpt-x", "llama3"])
        #expect(p.ai.model(in: p.imps[0].brain) == "openai/gpt-x")
        #expect(p.ai.model(in: p.imps[1].brain) == "llama3" && p.imps[1].brain?.model == "")
    }

    @Test func clicksAndKeysBecomeTriggers() throws {
        let p = try load()
        let clicks = p.shortcuts.filter { $0.trigger.kind == .clicks }
        #expect(clicks.count == 1 && clicks[0].command == .talk)       // a click talked, no double-click settings
        let keys = p.shortcuts.first { $0.name == "Translate" }
        #expect(keys?.trigger.kind == .keys && keys?.command == .ask && keys?.hotkey == Hotkey(keyCode: 17, modifiers: 4352))
        #expect(p.mouseGames && !p.rule(for: .dizzy).isEnabled)       // mouse games were off
        #expect(!p.rule(for: .smile).isEnabled)
    }
}
