package power

// Windows is planned for v3 through SetThreadExecutionState, which needs no admin,
// plus a power-scheme LIDACTION edit, which does. This stub exists so the platform
// boundary is compiled, not aspirational.

type unsupported struct{}

func newController() Controller { return unsupported{} }

func (unsupported) OnAC() (bool, error)           { return false, ErrUnsupported }
func (unsupported) IdleSeconds() (float64, error) { return 0, ErrUnsupported }
func (unsupported) Hold(Options) error            { return ErrUnsupported }
func (unsupported) Release() error                { return ErrUnsupported }
func (unsupported) Holding() bool                 { return false }
func (unsupported) Capabilities() Caps {
	return Caps{ExplainUnavailable: "Windows support is not implemented yet"}
}
