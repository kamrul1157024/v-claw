// Darwin-only. Installs a Carbon Apple Event handler for kAEReopenApplication,
// the event LaunchServices sends the already-running process when the user
// clicks the app icon. AppKit's default handler does nothing for a window-less
// LSUIElement app, so we override it and bounce into Go to open the window.
#include <Carbon/Carbon.h>
#include "_cgo_export.h"

static OSErr reopenHandler(const AppleEvent *event, AppleEvent *reply, SRefCon refcon) {
	(void)event;
	(void)reply;
	(void)refcon;
	goHandleReopen();
	return noErr;
}

void installReopenHandler(void) {
	// AEInstallEventHandler replaces any existing handler for this (class, id)
	// in the application dispatch table, including the one AppKit installed
	// during finishLaunching. false = application table, not the system table.
	AEInstallEventHandler(kCoreEventClass, kAEReopenApplication,
		NewAEEventHandlerUPP(reopenHandler), 0, false);
}
