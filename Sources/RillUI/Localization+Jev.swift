import RillCore

enum JevText: CaseIterable {
  case title, open, disclosure, saveKey, clearKey, keyReady, keyNotice, fragment, candidate, score
  case select, rubric, working, close, send
  case credentialTitle, polishingTitle, returnToComparison, cancelReturn, retryPreview, privacySettings
  case brandTitle, apiKey, apiKeyPlaceholder
  case providersTitle, settingsDescription, configureNotice, openSettings, invalidKey
}

extension L10n {
  static func jev(_ key: JevText, language: AppLanguage) -> String {
    return switch key {
    case .brandTitle: "Jev · TypeSafe"
    case .apiKey: L10n.resource("Localization.Jev.API.Key").string(for: language)
    case .apiKeyPlaceholder: L10n.resource("Localization.Jev.TypeSafe.API.Key").string(for: language)
    case .credentialTitle: L10n.resource("Localization.Jev.Jev.API.Key").string(for: language)
    case .polishingTitle: L10n.resource("Localization.Jev.Jev.polishing.prediction").string(for: language)
    case .returnToComparison: L10n.resource("Localization.Jev.Return.to.candidate.review").string(for: language)
    case .cancelReturn: L10n.resource("Localization.Jev.Cancel.return").string(for: language)
    case .retryPreview: L10n.resource("Localization.Jev.Prepare.a.new.preview").string(for: language)
    case .privacySettings: L10n.resource("Localization.Jev.Review.privacy.settings").string(for: language)
    case .providersTitle: L10n.resource("Localization.Jev.API.Providers").string(for: language)
    case .settingsDescription:
      L10n.resource("Localization.Jev.One.session.key.serves.Jev.candidate.scoring.and.polishing.prediction.Candidate.scoring.requires.confirmation").string(
        for: language)
    case .configureNotice: L10n.resource("Localization.Jev.Add.a.Jev.key.in.Settings.Voice.Models.API.Providers").string(for: language)
    case .openSettings: L10n.resource("Localization.Jev.Configure.Jev.API").string(for: language)
    case .invalidKey: L10n.resource("Localization.Jev.Enter.a.TypeSafe.API.key.with.8.512.visible.ASCII.characters.and.no.spaces").string(for: language)
    case .title: L10n.resource("Localization.Jev.Review.with.Jev").string(for: language)
    case .open: L10n.resource("Localization.Jev.Compare.with.Jev").string(for: language)
    case .disclosure: L10n.resource("Localization.Jev.Send.this.query.and.up.to.10.displayed.text.excerpts.or.file.names.to").string(for: language)
    case .saveKey: L10n.resource("Localization.Jev.Use.this.key").string(for: language)
    case .clearKey: L10n.resource("Localization.Jev.Clear.key").string(for: language)
    case .keyReady: L10n.resource("Localization.Jev.Key.stored.for.this.app.session.only.availability.is.checked.on.a.real.request").string(for: language)
    case .keyNotice: L10n.resource("Localization.Jev.Enter.a.key.for.this.session.It.is.not.written.to.settings.or.logs").string(for: language)
    case .fragment: L10n.resource("Localization.Jev.Text.excerpt.truncated").string(for: language)
    case .candidate: L10n.resource("Localization.Jev.Candidate").string(for: language)
    case .score: L10n.resource("Localization.Jev.Relevance.score.out.of.2").string(for: language)
    case .select: L10n.resource("Localization.Jev.Select.this.record").string(for: language)
    case .rubric:
      L10n.resource("Localization.Jev.0.unrelated.1.partly.relevant.2.directly.useful.Scores.are.not.correctness.probabilities.Selection").string(for: language)
    case .working: L10n.resource("Localization.Jev.Working.Close.to.cancel.A.sent.request.may.still.incur.usage").string(for: language)
    case .close: L10n.resource("Localization.Jev.Close").string(for: language)
    case .send: L10n.resource("Localization.Jev.Send.these.candidates.to.Jev").string(for: language)
    }
  }

  static func jevError(_ error: RecordRankingError, language: AppLanguage) -> String {
    switch error {
    case .privacyBlocked: return catalogString("jevError.privacyBlocked", language: language)
    case .changed: return catalogString("jevError.changed", language: language)
    case .missingKey: return catalogString("jevError.missingKey", language: language)
    case .unauthorized: return catalogString("jevError.unauthorized", language: language)
    case .invalidInput: return catalogString("jevError.invalidInput", language: language)
    case .busy: return catalogString("jevError.busy", language: language)
    case .rateLimited: return catalogString("jevError.rateLimited", language: language)
    case .invalidResponse: return catalogString("jevError.invalidResponse", language: language)
    case .unavailable: return catalogString("jevError.unavailable", language: language)
    }
  }
}
