import Testing

@testable import AthinaCore

@Suite struct SetupFlowTests {
  /// A missing permission comes next after Allow whether or not a first launch
  /// is walking through, as the Permissions window always opened after Allow.
  @Test func aMissingPermissionAlwaysComesNextAfterAllow() {
    for walksThrough in [true, false] {
      for hasModelPage in [true, false] {
        #expect(
          SetupFlow.afterAllow(
            walksThrough: walksThrough,
            permissionsGranted: false,
            hasModelPage: hasModelPage
          )
            == .permissions
        )
      }
    }
  }

  @Test func onlyAWalkThroughGoesOnToTheModelPage() {
    #expect(
      SetupFlow.afterAllow(walksThrough: true, permissionsGranted: true, hasModelPage: true)
        == .model
    )
    #expect(
      SetupFlow.afterAllow(walksThrough: false, permissionsGranted: true, hasModelPage: true)
        == nil
    )
  }

  /// With every permission granted and no model page, as in a hermetic replay,
  /// Allow closes the window, as it always has.
  @Test func allowClosesTheWindowWhenNothingIsLeft() {
    for walksThrough in [true, false] {
      #expect(
        SetupFlow.afterAllow(
          walksThrough: walksThrough,
          permissionsGranted: true,
          hasModelPage: false
        )
          == nil
      )
    }
  }

  @Test func continueAndBackStepThroughThePagesInOrder() {
    #expect(SetupFlow.page(after: .consent, hasModelPage: true) == .permissions)
    #expect(SetupFlow.page(after: .permissions, hasModelPage: true) == .model)
    #expect(SetupFlow.page(after: .model, hasModelPage: true) == .ready)
    #expect(SetupFlow.page(after: .ready, hasModelPage: true) == nil)
    #expect(SetupFlow.page(before: .consent, hasModelPage: true) == nil)
    #expect(SetupFlow.page(before: .ready, hasModelPage: true) == .model)
    #expect(SetupFlow.page(before: .model, hasModelPage: true) == .permissions)
  }

  /// Back mirrors Continue: a walk without the model page skips it both ways,
  /// and the dots count only the pages the walk through shows.
  @Test func backAndTheDotsSkipTheModelPageAsContinueDoes() {
    #expect(SetupFlow.pages(hasModelPage: true) == [.consent, .permissions, .model, .ready])
    #expect(SetupFlow.pages(hasModelPage: false) == [.consent, .permissions, .ready])
    for hasModelPage in [true, false] {
      let pages = SetupFlow.pages(hasModelPage: hasModelPage)
      for (index, page) in pages.enumerated() {
        #expect(SetupFlow.page(after: page, hasModelPage: hasModelPage) == pages[safe: index + 1])
        #expect(
          SetupFlow.page(before: page, hasModelPage: hasModelPage) == pages[safe: index - 1]
        )
        let step = SetupFlow.step(of: page, hasModelPage: hasModelPage)
        #expect(step.number == index + 1)
        #expect(step.count == pages.count)
      }
    }
    #expect(SetupFlow.page(before: .ready, hasModelPage: false) == .permissions)
  }

  /// The walk's pages are fixed when it begins: a launch that could need a key
  /// has the model page, one that cannot does not, and the count of dots is
  /// the same on every page of the walk, the last page included.
  @Test func theDotsCountTheSamePagesFromTheFirstPageToTheLast() {
    for needsKey in [true, false] {
      let walk = SetupFlow.atLaunch(requested: nil, hasConsent: false, needsKey: needsKey)
      #expect(walk.hasModelPage == needsKey)
      let counts = Set(
        SetupFlow.pages(hasModelPage: walk.hasModelPage).map {
          SetupFlow.step(of: $0, hasModelPage: walk.hasModelPage).count
        }
      )
      #expect(counts == [needsKey ? 4 : 3])
    }
  }

  /// Continue skips the model page exactly when Allow does: when the walk has
  /// no model page.
  @Test func continueSkipsTheModelPageAsAllowDoes() {
    for hasModelPage in [true, false] {
      let afterContinue = SetupFlow.page(after: .permissions, hasModelPage: hasModelPage)
      let afterAllow = SetupFlow.afterAllow(
        walksThrough: true,
        permissionsGranted: true,
        hasModelPage: hasModelPage
      )
      #expect(afterContinue == (hasModelPage ? .model : .ready))
      #expect((afterContinue == .model) == (afterAllow == .model))
    }
    #expect(SetupFlow.page(after: .consent, hasModelPage: false) == .permissions)
  }

  /// A launch with no consent walks through from the consent page even when
  /// `--open` names another page, since no permission is asked about first.
  @Test func aLaunchWithNoConsentStartsOnTheConsentPage() {
    for requested in [nil] + SetupPage.allCases.map(Optional.some) {
      #expect(
        SetupFlow.atLaunch(requested: requested, hasConsent: false, needsKey: true)
          == SetupState(page: .consent, walksThrough: true, hasModelPage: true)
      )
    }
    #expect(
      SetupFlow.atLaunch(requested: .model, hasConsent: true, needsKey: true)
        == SetupState(page: .model, walksThrough: false, hasModelPage: true)
    )
    #expect(
      SetupFlow.atLaunch(requested: nil, hasConsent: true, needsKey: false)
        == SetupState(page: .permissions, walksThrough: false, hasModelPage: false)
    )
  }

  /// Opening any page into a window that shows an unanswered consent page
  /// keeps it there, walking through or not.
  @Test func anUnansweredConsentPageIsNeverReplaced() {
    for walksThrough in [true, false] {
      let consent = SetupState(page: .consent, walksThrough: walksThrough)
      for page in SetupPage.allCases {
        #expect(
          SetupFlow.opening(page, from: consent, isOpen: true, hasConsent: false) == consent
        )
      }
    }
  }

  /// A page opened into an open walk through keeps the walk going, with the
  /// pages the walk had.
  @Test func openingAPageKeepsAnOpenWalkThroughGoing() {
    for hasModelPage in [true, false] {
      let walk = SetupState(page: .model, walksThrough: true, hasModelPage: hasModelPage)
      #expect(
        SetupFlow.opening(.consent, from: walk, isOpen: true, hasConsent: false)
          == SetupState(page: .consent, walksThrough: true, hasModelPage: hasModelPage)
      )
      #expect(
        SetupFlow.opening(.permissions, from: walk, isOpen: false, hasConsent: true)
          == SetupState(page: .permissions, walksThrough: false, hasModelPage: hasModelPage)
      )
    }
    let answered = SetupState(page: .consent, walksThrough: true)
    #expect(
      SetupFlow.opening(.permissions, from: answered, isOpen: true, hasConsent: true)
        == SetupState(page: .permissions, walksThrough: true)
    )
  }

  /// A consent page for a provider that already has consent is never
  /// answered again: Continue in a walk through, Done on its own.
  @Test func anAnsweredConsentPageOnlyMovesOnOrCloses() {
    for granted in [true, false] {
      #expect(
        SetupFlow.footer(
          on: SetupState(page: .consent, walksThrough: true),
          hasConsent: true,
          permissionsGranted: granted
        ) == .continue
      )
      #expect(
        SetupFlow.footer(
          on: SetupState(page: .consent, walksThrough: false),
          hasConsent: true,
          permissionsGranted: granted
        ) == .done
      )
      for walksThrough in [true, false] {
        #expect(
          SetupFlow.footer(
            on: SetupState(page: .consent, walksThrough: walksThrough),
            hasConsent: false,
            permissionsGranted: granted
          ) == .answer
        )
      }
    }
    #expect(
      SetupFlow.footer(
        on: SetupState(page: .permissions, walksThrough: false),
        hasConsent: true,
        permissionsGranted: false
      ) == .notNow
    )
    #expect(
      SetupFlow.footer(
        on: SetupState(page: .ready, walksThrough: true),
        hasConsent: true,
        permissionsGranted: false
      ) == .done
    )
  }

  /// The last page says Athina is set up only when nothing required is
  /// missing, and otherwise names what is still to do and where.
  @Test func theReadyPageSaysWhatIsStillMissing() {
    let granted = PermissionStatus(screenRecording: true, accessibility: true)
    let ready = SetupReadiness(permissions: granted, needsKey: false)
    #expect(ready.isSetUp)
    #expect(ready.heading == "Athina is set up")
    #expect(ready.stillToDo.isEmpty)

    let noScreen = SetupReadiness(
      permissions: PermissionStatus(screenRecording: false, accessibility: true, microphone: true),
      needsKey: false
    )
    #expect(!noScreen.isSetUp)
    #expect(noScreen.heading != "Athina is set up")
    #expect(
      noScreen.stillToDo == [
        "Screen Recording is still off. Allow it from Permissions in the Athina menu."
      ]
    )

    let nothing = SetupReadiness(
      permissions: PermissionStatus(screenRecording: false, accessibility: false),
      needsKey: true
    )
    #expect(
      nothing.stillToDo == [
        "Screen Recording and Accessibility are still off. Allow them from Permissions in the Athina menu.",
        "An API key is still needed. Add it in Settings > Models.",
      ]
    )

    let noKey = SetupReadiness(permissions: granted, needsKey: true)
    #expect(!noKey.isSetUp)
    #expect(noKey.stillToDo == ["An API key is still needed. Add it in Settings > Models."])
  }

  /// Only the required pair counts: the voice pair is optional.
  @Test func theVoicePermissionsAreNotMissing() {
    let readiness = SetupReadiness(
      permissions: PermissionStatus(screenRecording: true, accessibility: true),
      needsKey: false
    )
    #expect(readiness.isSetUp)
  }

  /// The consent page keeps the title the consent window had, and each page has
  /// its own, so the window's title always says where the person is.
  @Test func eachPageHasItsOwnTitle() {
    #expect(SetupPage.consent.title == "Athina and Your Privacy")
    #expect(Set(SetupPage.allCases.map(\.title)).count == SetupPage.allCases.count)
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
