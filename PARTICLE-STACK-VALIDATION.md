# Particle integration dependencies

PR #88 supplies the QLI platform image and the separate 1.4+ release stream,
with kernel `6.8.0-1058.59+particle9` and BP firmware `2.0.8`. The incomplete
Particle RPM integration is split into a follow-up composer PR.

The following component PRs are prerequisites for accepting the full Particle
stack; they do not need to land before the platform image PR #88:

- [Overlays #44](https://github.com/particle-iot/tachyon-overlays/pull/44): QLI common/headless stacks.
- [Overlay tool #7](https://github.com/particle-iot/tachyon-overlay-tool/pull/7): offline RPM installation.
- [Particle Linux #154](https://github.com/particle-iot-inc/particle-linux/pull/154): native packaging, version reporting and durable bootstrap.
- [RIL #63](https://github.com/particle-iot-inc/particle-tachyon-ril/pull/63): packaging, shared modem access and NetworkManager activation.
- [Syscon #36](https://github.com/particle-iot-inc/particle-tachyon-syscon/pull/36): packaging and verified firmware/flasher inputs.
- [CLI #938](https://github.com/particle-iot/particle-cli/pull/938): QLI selection and GPT-preserving host setup. This gates the host setup experience, not image composition.

Landing these PRs alone is insufficient: build the component/utility and
NetworkManager RPMs against the locked QLI SDK, pin actual outputs and complete
NA/RoW image and head2 acceptance. The current integration has no package lock
entries. The repository has no QLI SDK runner configured, and package-build CI
wiring remains local because the GitHub credential lacks `workflow` scope.
Embroid also needs reauthentication before new hardware acceptance can run.

The existing Kigen LPA is pinned in the follow-up integration; no Kigen PR has
been created or shown necessary. Kernel/BP adoption is already merged in
[24.04 composer #90](https://github.com/particle-iot/tachyon-composer/pull/90).
