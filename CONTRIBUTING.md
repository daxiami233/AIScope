# Contributing

Thanks for helping improve AIScope.

## Local Setup

1. Open `AIScope.xcodeproj` in Xcode.
2. Select the `AIScope` scheme.
3. Build and run on macOS 14.0 or later.

## Provider Changes

Provider implementations live in `AIScope/Providers/`.

When adding or changing a provider:

- Keep network calls scoped to the provider.
- Do not log secrets, tokens, cookies, or raw credential payloads.
- Prefer local files and Keychain reads over manual credential entry.
- Return `ProviderError.actionRequired` for user-fixable auth issues.
- Keep quota labels stable where possible, because they drive reset notifications.

## Pull Requests

- Keep changes focused.
- Include screenshots for UI changes.
- Run a Debug build before submitting.
- Mention any provider API assumptions in the PR description.
