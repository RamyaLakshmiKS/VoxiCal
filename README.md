# VoxiCal
VoxiCal is your voice-activated AI executive assistant. Simply speak to check your schedule, retrieve meeting details and manage appointments completely hands-free.

## Developer Notes

### Running Evals

Evals test the agent's calendar reasoning using mock data and Apple Intelligence. No iPhone required — they run on the iOS simulator using your Mac's Apple Intelligence backend.

**Prerequisites:** Apple Silicon Mac with Apple Intelligence enabled, Xcode 16+.

```bash
xcodebuild test \
  -project ios/VoxiCal/VoxiCal.xcodeproj \
  -scheme VoxiCal \
  -destination "platform=iOS Simulator,name=iPhone 17 Pro" \
  -only-testing:VoxiCalTests
```

Results are printed to the console under `EVALUATION RESULTS`. The `VoxiCalTests` target compiles only the eval-relevant source files — it does not launch the full app.
