package power

// Linux is planned for v2 through a systemd-logind Inhibit. That call accepts
// handle-lid-switch, so lid blocking will need no privilege and Caps will differ from
// macOS. This stub exists so the platform boundary is compiled, not aspirational.

type unsupported struct{}

func newController() Controller { return unsupported{} }

func (unsupported) OnAC() (bool, error)           { return false, ErrUnsupported }
func (unsupported) IdleSeconds() (float64, error) { return 0, ErrUnsupported }
func (unsupported) Hold(Options) error            { return ErrUnsupported }
func (unsupported) Release() error                { return ErrUnsupported }
func (unsupported) Holding() bool                 { return false }
func (unsupported) Capabilities() Caps {
	return Caps{ExplainUnavailable: "Linux support is not implemented yet"}
}
