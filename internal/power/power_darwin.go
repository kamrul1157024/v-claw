package power

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation -framework ApplicationServices
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>

int vc_on_ac(void) {
	CFTypeRef snap = IOPSCopyPowerSourcesInfo();
	if (snap == NULL) return -1;
	CFStringRef src = IOPSGetProvidingPowerSourceType(snap);
	if (src == NULL) { CFRelease(snap); return -1; }
	int ac = CFStringCompare(src, CFSTR(kIOPMACPowerKey), 0) == kCFCompareEqualTo;
	CFRelease(snap);
	return ac;
}

unsigned int vc_assert(const char *type, const char *name) {
	CFStringRef t = CFStringCreateWithCString(NULL, type, kCFStringEncodingUTF8);
	CFStringRef n = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
	IOPMAssertionID id = 0;
	IOReturn r = IOPMAssertionCreateWithName(t, kIOPMAssertionLevelOn, n, &id);
	CFRelease(t);
	CFRelease(n);
	return r == kIOReturnSuccess ? (unsigned int)id : 0;
}

void vc_release(unsigned int id) { IOPMAssertionRelease((IOPMAssertionID)id); }

double vc_idle_seconds(void) {
	return CGEventSourceSecondsSinceLastEventType(
		kCGEventSourceStateHIDSystemState, kCGAnyInputEventType);
}
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

// assertionName is what shows up in `pmset -g assertions`, so the live state stays
// auditable from any terminal.
const assertionName = "v-claw"

const (
	typeIdleSystem  = "PreventUserIdleSystemSleep"
	typeIdleDisplay = "PreventUserIdleDisplaySleep"
	typeSystem      = "PreventSystemSleep"
)

// LidBlockProbe reports whether the privileged daemon is installed and running. It is
// set by the app at start, since only the app can check launchd.
type darwinController struct {
	held map[string]C.uint

	// DaemonPresent is consulted by Capabilities. The daemon owns pmset disablesleep,
	// which is the only guaranteed lid block on macOS.
	DaemonPresent func() (bool, string)
}

func newController() Controller {
	return &darwinController{held: map[string]C.uint{}}
}

func (c *darwinController) OnAC() (bool, error) {
	switch C.vc_on_ac() {
	case 1:
		return true, nil
	case 0:
		return false, nil
	default:
		return false, errors.New("power: IOPSCopyPowerSourcesInfo failed")
	}
}

func (c *darwinController) IdleSeconds() (float64, error) {
	return float64(C.vc_idle_seconds()), nil
}

func (c *darwinController) Holding() bool { return len(c.held) > 0 }

func (c *darwinController) Hold(o Options) error {
	want := map[string]bool{
		typeIdleSystem: true,
		// PreventSystemSleep is the assertion powerd counts in its clamshell rule, so
		// it is the app's best effort at lid blocking without the daemon.
		typeSystem:      o.BlockLidSleep,
		typeIdleDisplay: o.KeepDisplayOn,
	}

	for typ, on := range want {
		switch {
		case on && c.held[typ] == 0:
			id, err := create(typ)
			if err != nil {
				return err
			}
			c.held[typ] = id
		case !on && c.held[typ] != 0:
			C.vc_release(c.held[typ])
			delete(c.held, typ)
		}
	}
	return nil
}

func (c *darwinController) Release() error {
	for typ, id := range c.held {
		C.vc_release(id)
		delete(c.held, typ)
	}
	return nil
}

func (c *darwinController) Capabilities() Caps {
	caps := Caps{LidBlockNeedsPrivilege: true}
	if c.DaemonPresent == nil {
		caps.ExplainUnavailable = "helper not installed: run `sudo make install-daemon`"
		return caps
	}
	present, why := c.DaemonPresent()
	caps.LidBlockAvailable = present
	caps.ExplainUnavailable = why
	return caps
}

func create(typ string) (C.uint, error) {
	ct, cn := C.CString(typ), C.CString(assertionName)
	defer C.free(unsafe.Pointer(ct))
	defer C.free(unsafe.Pointer(cn))

	id := C.vc_assert(ct, cn)
	if id == 0 {
		return 0, fmt.Errorf("power: IOPMAssertionCreateWithName(%s) failed", typ)
	}
	return id, nil
}
