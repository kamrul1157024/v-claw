//go:build darwin

// Probe for the cgo APIs v-claw depends on. Not shipped.
//
//	go run ./experiments/probe            read power source + idle, exit
//	go run ./experiments/probe -hold      hold PreventSystemSleep until Ctrl-C
package main

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation -framework ApplicationServices
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <ApplicationServices/ApplicationServices.h>
#include <stdlib.h>

// Returns 1 on AC, 0 on battery, -1 on error.
int vc_on_ac(void) {
	CFTypeRef snap = IOPSCopyPowerSourcesInfo();
	if (snap == NULL) return -1;
	CFStringRef src = IOPSGetProvidingPowerSourceType(snap);
	if (src == NULL) { CFRelease(snap); return -1; }
	int ac = CFStringCompare(src, CFSTR(kIOPMACPowerKey), 0) == kCFCompareEqualTo;
	CFRelease(snap);
	return ac;
}

// Creates an assertion. Returns the id, or 0 on failure.
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
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"
	"unsafe"
)

func assert(typ, name string) uint32 {
	ct, cn := C.CString(typ), C.CString(name)
	defer C.free(unsafe.Pointer(ct))
	defer C.free(unsafe.Pointer(cn))
	return uint32(C.vc_assert(ct, cn))
}

func main() {
	hold := flag.Bool("hold", false, "hold assertions until interrupted")
	flag.Parse()

	fmt.Println("== power source ==")
	switch C.vc_on_ac() {
	case 1:
		fmt.Println("  AC Power")
	case 0:
		fmt.Println("  Battery Power")
	default:
		fmt.Println("  ERROR: IOPSCopyPowerSourcesInfo failed")
	}

	fmt.Printf("== idle ==\n  %.1fs since last input\n", float64(C.vc_idle_seconds()))

	types := []string{
		"PreventUserIdleSystemSleep",
		"PreventUserIdleDisplaySleep",
		"PreventSystemSleep",
	}

	fmt.Println("== assertions ==")
	var ids []uint32
	for _, t := range types {
		id := assert(t, "v-claw")
		if id == 0 {
			fmt.Printf("  %-28s FAILED\n", t)
			continue
		}
		fmt.Printf("  %-28s ok (id %d)\n", t, id)
		ids = append(ids, id)
	}

	if !*hold {
		for _, id := range ids {
			C.vc_release(C.uint(id))
		}
		fmt.Println("\nreleased. verify with: pmset -g assertions | grep v-claw")
		return
	}

	fmt.Println("\nHOLDING. Verify:  pmset -g assertions | grep v-claw")
	fmt.Println("Close the lid now. Ctrl-C to release.")

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	start := time.Now()
	<-sig

	for _, id := range ids {
		C.vc_release(C.uint(id))
	}
	fmt.Printf("\nreleased after %s\n", time.Since(start).Round(time.Second))
}
