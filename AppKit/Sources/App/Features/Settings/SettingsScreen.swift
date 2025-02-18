import AppDevUtils
import ComposableArchitecture
import Inject
import Popovers
import Setting
import SwiftUI
import SwiftUIIntrospect

// MARK: - SettingsScreen

struct SettingsScreen: ReducerProtocol {
  struct State: Equatable {
    var modelSelector = ModelSelector.State()
    var availableLanguages: IdentifiedArrayOf<VoiceLanguage> = []
    var appVersion: String = ""
    var buildNumber: String = ""
    var freeSpace: String = ""
    var takenSpace: String = ""
    var takenSpacePercentage: Double = 0
    @BindingState var settings: Settings = .init()
    @PresentationState var alert: AlertState<Action.Alert>?
    @BindingState var isICloudSyncInProgress = false
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case modelSelector(ModelSelector.Action)
    case task
    case updateInfo
    case openGitHub
    case openPersonalWebsite
    case deleteStorageTapped
    case rateAppTapped
    case reportBugTapped
    case suggestFeatureTapped

    case showError(EquatableErrorWrapper)
    case alert(PresentationAction<Alert>)

    enum Alert: Equatable {
      case deleteDialogConfirmed
    }
  }

  @Dependency(\.transcriptionWorker) var transcriptionWorker: TranscriptionWorkerClient
  @Dependency(\.settings) var settingsClient: SettingsClient
  @Dependency(\.openURL) var openURL: OpenURLEffect
  @Dependency(\.build) var build: BuildClient
  @Dependency(\.storage) var storage: StorageClient

  var body: some ReducerProtocol<State, Action> {
    BindingReducer()
      .onChange(of: \.settings.isICloudSyncEnabled) { oldValue, newValue in
        Reduce<State, Action> { _, _ in
          if oldValue != newValue, newValue {
            return .run { send in
              if settingsClient.getSettings().isICloudSyncEnabled != newValue {
                await send(.set(\.$isICloudSyncInProgress, true))
                try await storage.uploadRecordingsToICloud()
                await send(.set(\.$isICloudSyncInProgress, false))
              }
              try await settingsClient.updateSettings(settingsClient.getSettings().with(\.isICloudSyncEnabled, setTo: newValue))
            } catch: { error, send in
              await send(.set(\.$isICloudSyncInProgress, false))
              await send(.set(\.$settings, settingsClient.getSettings()))
              await send(.showError(error.equatable))
            }
          } else {
            return .none
          }
        }
      }

    Scope(state: \.modelSelector, action: /Action.modelSelector) {
      ModelSelector()
    }

    Reduce<State, Action> { state, action in
      switch action {
      case .binding:
        return .run { [settings = state.settings] _ in
          try await settingsClient.updateSettings(settings)
        } catch: { error, send in
          await send(.set(\.$settings, settingsClient.getSettings()))
          await send(.showError(error.equatable))
        }

      case .modelSelector:
        return .none

      case .task:
        updateInfo(state: &state)
        return .run { send in
          for try await settings in settingsClient.settingsPublisher().values {
            await send(.set(\.$settings, settings))
          }
        } catch: { error, send in
          await send(.showError(error.equatable))
        }

      case .updateInfo:
        updateInfo(state: &state)
        state.modelSelector = .init()
        return .send(.modelSelector(.onAppear))

      case .openGitHub:
        return .run { _ in
          await openURL(build.githubURL())
        }

      case .openPersonalWebsite:
        return .run { _ in
          await openURL(build.personalWebsiteURL())
        }

      case .deleteStorageTapped:
        createDeleteConfirmationDialog(state: &state)
        return .none

      case .alert(.presented(.deleteDialogConfirmed)):
        return .run { send in
          try await storage.deleteStorage()
          try await settingsClient.setValue(.default, forKey: \.selectedModel)
          await send(.updateInfo)
        } catch: { error, send in
          await send(.showError(error.equatable))
        }

      case let .showError(error):
        state.alert = .error(error)
        return .none

      case .rateAppTapped:
        return .run { _ in
          await openURL(build.appStoreReviewURL())
        }

      case .reportBugTapped:
        return .run { _ in
          await openURL(build.bugReportURL())
        }

      case .suggestFeatureTapped:
        return .run { _ in
          await openURL(build.featureRequestURL())
        }

      case .alert:
        return .none
      }
    }.ifLet(\.$alert, action: /Action.alert)
  }

  private func updateInfo(state: inout State) {
    state.appVersion = build.version()
    state.buildNumber = build.buildNumber()
    state.freeSpace = storage.freeSpace().readableString
    state.takenSpace = storage.takenSpace().readableString
    state.takenSpacePercentage = min(1, max(0, 1 - Double(storage.freeSpace()) / Double(storage.freeSpace() + storage.takenSpace())))
    state.availableLanguages = transcriptionWorker.getAvailableLanguages().identifiedArray
  }

  private func setSettings<Value: Codable>(_ value: Value, forKey keyPath: WritableKeyPath<Settings, Value>) -> EffectPublisher<Action, Never> {
    .run { _ in
      try await settingsClient.setValue(value, forKey: keyPath)
    } catch: { error, send in
      await send(.showError(error.equatable))
    }
  }

  private func createDeleteConfirmationDialog(state: inout State) {
    state.alert = AlertState {
      TextState("Confirmation")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
      ButtonState(role: .destructive, action: .deleteDialogConfirmed) {
        TextState("Delete")
      }
    } message: {
      TextState("Are you sure you want to delete all recordings and all downloaded models?")
    }
  }
}

// MARK: - RemoteTranscriptionImage

struct RemoteTranscriptionImage: View {
  @ObserveInjection var inject

  @State private var animating = false

  private let featureDescription = "Transcribe your recordings in the cloud super fast using the most capable"
  private let modelName = "Large-v2 Whisper model"

  var body: some View {
    VStack(spacing: 0) {
      WhisperBoardKitAsset.remoteTranscription.swiftUIImage
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(height: 70)
        .padding(.grid(2))
        .background(
          WhisperBoardKitAsset.remoteTranscription.swiftUIImage
            .resizable()
            .blur(radius: animating ? 30 : 20)
            .padding(.grid(2))
            .opacity(animating ? 1.0 : 0.3)
            .animation(Animation.interpolatingSpring(stiffness: 3, damping: 0.3).repeatForever(autoreverses: false), value: animating)
        )
        .onAppear { animating = true }

      VStack(spacing: 0) {
        Text(featureDescription)
          .font(.DS.headlineS)
          .foregroundColor(.DS.Text.base)
        Text(modelName).shadow(color: .black, radius: 1, y: 1)
          .background(Text(modelName).blur(radius: 7))
          .font(.DS.headlineL)
          .foregroundStyle(
            LinearGradient(
              colors: [.DS.Text.accent, .DS.Background.accentAlt],
              startPoint: .leading,
              endPoint: .trailing
            )
          )
      }
      .multilineTextAlignment(.center)
      .padding([.leading, .bottom, .trailing], .grid(2))
    }
    .enableInjection()
  }
}

// MARK: - SettingsScreenView

struct SettingsScreenView: View {
  struct ViewState: Equatable {
    var selectedModelReadableName: String
    var availableLanguages: IdentifiedArrayOf<VoiceLanguage>
    var appVersion: String
    var buildNumber: String
    var freeSpace: String
    var takenSpace: String
    var takenSpacePercentage: Double
    @BindingViewState var settings: Settings
    @BindingViewState var isICloudSyncInProgress: Bool
  }

  @ObserveInjection var inject

  let store: StoreOf<SettingsScreen>

  @ObservedObject var viewStore: ViewStore<ViewState, SettingsScreen.Action>

  @State var debugPresent = false

  var modelSelectorStore: StoreOf<ModelSelector> {
    store.scope(state: \.modelSelector, action: SettingsScreen.Action.modelSelector)
  }

  init(store: StoreOf<SettingsScreen>) {
    self.store = store
    viewStore = ViewStore(store) { state in
      ViewState(
        selectedModelReadableName: state.modelSelector.selectedModel.readableName,
        availableLanguages: state.availableLanguages,
        appVersion: state.appVersion,
        buildNumber: state.buildNumber,
        freeSpace: state.freeSpace,
        takenSpace: state.takenSpace,
        takenSpacePercentage: state.takenSpacePercentage,
        settings: state.$settings,
        isICloudSyncInProgress: state.$isICloudSyncInProgress
      )
    }
  }

  var body: some View {
    SettingStack {
      SettingPage(title: "Settings", backgroundColor: .clear) {
        SettingGroup(header: "Local Transcription", backgroundColor: .DS.Background.secondary) {
          SettingPage(
            title: "Models",
            selectedChoice: viewStore.selectedModelReadableName,
            backgroundColor: .DS.Background.primary,
            previewConfiguration: .init(icon: .system(icon: "square.and.arrow.down", backgroundColor: .systemBlue))
          ) {
            SettingGroup(footer: .modelSelectorFooter) {}

            SettingGroup(header: "Whisper models", backgroundColor: .DS.Background.secondary) {
              SettingCustomView(id: "models") {
                ForEachStore(modelSelectorStore.scope(state: \.modelRows, action: ModelSelector.Action.modelRow)) { modelRowStore in
                  ModelRowView(store: modelRowStore)
                }
                .removeClipToBounds()
              }
            }
          }

          SettingPicker(
            icon: .system(icon: "globe", backgroundColor: .systemGreen.darken(by: 0.1)),
            title: "Language",
            choices: viewStore.availableLanguages.map(\.name.titleCased),
            selectedIndex: Binding(
              get: { viewStore.availableLanguages.firstIndex(of: viewStore.settings.voiceLanguage) ?? 0 },
              set: { viewStore.$settings.voiceLanguage.wrappedValue = viewStore.availableLanguages[$0] }
            ),
            choicesConfiguration: .init(
              pickerDisplayMode: .menu,
              groupBackgroundColor: .DS.Background.secondary
            )
          )
        }

        #if DEBUG
          SettingGroup(header: "Remote Transcription", backgroundColor: .DS.Background.secondary) {
            SettingCustomView(id: "remote_transcription") {
              RemoteTranscriptionImage()
            }
            SettingToggle(title: "Fast Cloud Transcription", isOn: viewStore.$settings.isRemoteTranscriptionEnabled)
          }

          SettingGroup(header: "Debug", backgroundColor: .DS.Background.secondary) {
            SettingToggle(title: "🪄 Enable Fixtures", isOn: viewStore.$settings.useMockedClients)
            SettingButton(icon: .system(icon: "ladybug", backgroundColor: .systemRed.darken(by: 0.05)), title: "Show logs") {
              debugPresent = true
            }
            SettingCustomView {
              ZStack {}.popover(present: $debugPresent) { (attr: inout Popover.Attributes) in
                attr.position = .relative(popoverAnchors: [.center])
                attr.presentation.transition = .move(edge: .bottom).combined(with: .scale)
                attr.presentation.animation = .gentleBounce()
                attr.source = .stayAboveWindows
                attr.dismissal.mode = [.tapOutside, .dragDown]
                attr.screenEdgePadding = UIEdgeInsets(top: 32, left: 16, bottom: 32, right: 16)
              } view: {
                ScrollView {
                  Text((try? String(contentsOfFile: Configs.logFileURL.path())) ?? "No logs...")
                    .font(.footnote)
                    .monospaced()
                    .padding()
                }
                .foregroundColor(.white)
                .background(Color.systemBlue)
                .cornerRadius(16)
              }
            }
          }
        #endif

        SettingGroup(header: "Storage", backgroundColor: .DS.Background.secondary) {
          SettingCustomView {
            VStack(alignment: .leading, spacing: .grid(1)) {
              HStack(spacing: 0) {
                Text("Taken: \(viewStore.takenSpace)")
                  .font(.DS.bodyM)
                  .foregroundColor(.DS.Text.base)
                Spacer()
                Text("Available: \(viewStore.freeSpace)")
                  .font(.DS.bodyM)
                  .foregroundColor(.DS.Text.base)
              }

              GeometryReader { geometry in
                HStack(spacing: 0) {
                  LinearGradient.easedGradient(
                    colors: [
                      .systemPurple,
                      .systemOrange,
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                  )
                  .frame(width: geometry.size.width * viewStore.takenSpacePercentage)
                  Color.DS.Background.tertiary
                }
              }
              .frame(height: .grid(4))
              .continuousCornerRadius(.grid(1))
            }
            .padding(.horizontal, .grid(4))
            .padding(.vertical, .grid(2))
            .removeClipToBounds()
          }

          #if DEBUG
            SettingCustomView(id: "icloud") {
              HStack(spacing: 12) {
                SettingIconView(icon: .system(icon: "icloud.and.arrow.up", backgroundColor: .systemPurple.darken(by: 0.2)))

                Text("iCloud Sync")
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 14)

                Toggle("", isOn: viewStore.$settings.isICloudSyncEnabled)
                  .labelsHidden()
              }
              .padding(.horizontal, 14)
              .accessibilityElement(children: .combine)
              .overlay {
                if viewStore.isICloudSyncInProgress {
                  ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    ProgressView().accentColor(.DS.Text.accent)
                  }
                }
              }
            }
          #endif

          SettingButton(icon: .system(icon: "trash", backgroundColor: .systemRed.darken(by: 0.1)), title: "Delete Storage", indicator: nil) {
            viewStore.send(.deleteStorageTapped)
          }
        }

        SettingGroup(backgroundColor: .DS.Background.secondary) {
          SettingButton(icon: .system(icon: "star.fill", backgroundColor: .systemYellow.darken(by: 0.05)), title: "Rate the App") {
            viewStore.send(.rateAppTapped)
          }

          SettingButton(icon: .system(icon: "exclamationmark.triangle", backgroundColor: .systemRed), title: "Report a Bug") {
            viewStore.send(.reportBugTapped)
          }

          SettingButton(icon: .system(icon: "sparkles", backgroundColor: .systemPurple.darken(by: 0.1)), title: "Suggest New Feature") {
            viewStore.send(.suggestFeatureTapped)
          }
        }

        SettingCustomView(id: "Footer", titleForSearch: "GitHub") {
          VStack(spacing: .grid(1)) {
            Text("v\(viewStore.appVersion)(\(viewStore.buildNumber))")
              .font(.DS.bodyM)
              .foregroundColor(.DS.Text.subdued)
            Text("Made with ♥ in Amsterdam")
              .font(.DS.bodyM)
              .mask {
                LinearGradient.easedGradient(
                  colors: [
                    .systemPurple,
                    .systemRed,
                  ],
                  startPoint: .bottomLeading,
                  endPoint: .topTrailing
                )
              }
            Button { viewStore.send(.openPersonalWebsite) } label: {
              Text("by Igor Tarasenko")
                .font(.DS.bodyM)
                .foregroundColor(.DS.Text.accentAlt)
            }
          }
          .frame(maxWidth: .infinity)

          HStack(spacing: .grid(1)) {
            Button("Saik0s/Whisperboard") {
              viewStore.send(.openGitHub)
            }
          }
          .buttonStyle(SmallButtonStyle())
          .frame(maxWidth: .infinity)
          .onAppear {
            viewStore.send(.modelSelector(.onAppear))
            viewStore.send(.updateInfo)
          }
          .removeNavigationBackground()
        }
      }
    }
    .environment(\.settingBackgroundColor, .DS.Background.primary)
    .environment(\.settingSecondaryBackgroundColor, .DS.Background.secondary)
    .alert(store: modelSelectorStore.scope(state: \.$alert, action: { .alert($0) }))
    .alert(store: store.scope(state: \.$alert, action: { .alert($0) }))
    .task { viewStore.send(.task) }
    .enableInjection()
  }
}

// MARK: - SmallButtonStyle

struct SmallButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.DS.bodyM)
      .foregroundColor(.DS.Text.accentAlt)
      .padding(.horizontal, .grid(2))
      .padding(.vertical, .grid(1))
      .background(
        RoundedRectangle(cornerRadius: .grid(1))
          .fill(Color.DS.Background.accentAlt.opacity(0.2))
      )
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
  }
}

private extension String {
  static let modelSelectorFooter = """
  Whisper ASR, by OpenAI, is an advanced system that converts spoken words into written text. It's perfect for transcribing conversations or speeches.

  The model is a neural network that takes an audio file as input and outputs a sequence of characters.
  """
}

// MARK: - SettingsScreen_Previews

struct SettingsScreen_Previews: PreviewProvider {
  struct ContentView: View {
    var body: some View {
      SettingsScreenView(
        store: Store(
          initialState: SettingsScreen.State(),
          reducer: { SettingsScreen() }
        )
      )
    }
  }

  static var previews: some View {
    ContentView()
  }
}
