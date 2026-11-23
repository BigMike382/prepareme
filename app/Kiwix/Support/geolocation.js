// Bridge the HTML5 Geolocation API to CoreLocation via a script message handler.
// This lets map ZIM files use navigator.geolocation; The native side prompts the user for CoreLocation
// permission on first use. Supports both getCurrentPosition (one-shot) and
// watchPosition (continuous).
// PrepareMe (games plan phase 2, 2026-11-14): the app answers every request "permission denied", and this script runs
// at document start in every frame and covers the prototype too, so no page script reaches the browser's own
// geolocation (which asked for the device's location by itself, phase 2's check). Where no bridge is set up (a link
// preview), it denies on its own.
(function () {
    const handler = (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.geolocation) || {
        postMessage: () => setTimeout(() => window.__kiwixGeolocationResolve({
            error: { code: 1, message: "Location is off for library pages." } }), 0),
    };

    let pending = new Array();
    let nextId = 1;

    function deliverSuccess(success, payload) {
        if (typeof success !== "function") {
            return;
        }
        success({
            coords: {
                latitude: payload.coords.latitude,
                longitude: payload.coords.longitude,
                accuracy: payload.coords.accuracy,
                altitude: payload.coords.altitude ?? null,
                altitudeAccuracy: payload.coords.altitudeAccuracy ?? null,
                heading: payload.coords.heading ?? null,
                speed: payload.coords.speed ?? null,
            },
            timestamp: payload.timestamp,
        });
    }

    function deliverError(error, err) {
        if (typeof error !== "function") {
            return;
        }
        error({
            code: err.code,
            message: err.message,
            PERMISSION_DENIED: 1,
            POSITION_UNAVAILABLE: 2,
            TIMEOUT: 3,
        });
    }

    window.__kiwixGeolocationResolve = function (payload) {
        if (payload && payload.coords) {
            pending.forEach((entry) => {
                deliverSuccess(entry.success, payload);
            });
        } else if (payload && payload.error) {
            pending.forEach((entry) => {
                deliverError(entry.error, payload.error);
            });
            if (payload.error.code === 1) {
                // on permission denied, clear out all pending
                pending = new Array();
                return;
            }
        }
        // remove all one-shot requests, they have been served
        pending = pending.filter((entry) => entry.isWatch == true);
    };

    function getCurrentPosition(success, error, options) {
        const id = nextId++;
        const entry = { id: id, success: success, error: error, isWatch: false };
        pending.push(entry);
        handler.postMessage({
            type: "getCurrentPosition",
            id: id,
            highAccuracy: !!(options && options.enableHighAccuracy),
        });
    }

    function watchPosition(success, error, options) {
        const id = nextId++;
        const entry = { id: id, success: success, error: error, isWatch: true };
        pending.push(entry);
        handler.postMessage({
            type: "watchPosition",
            id: id,
            highAccuracy: !!(options && options.enableHighAccuracy),
        });
        return id;
    }

    function clearWatch(id) {
        pending = pending.filter((entry) => { entry.id !== id });
        handler.postMessage({ type: "clearWatch", id: id });
    }

    const shim = {
        getCurrentPosition: getCurrentPosition,
        watchPosition: watchPosition,
        clearWatch: clearWatch,
    };
    let installed = false;
    // The prototype's getter first (PrepareMe): left in place, a page could call it to reach the native object
    for (const target of [Object.getPrototypeOf(navigator), navigator]) {
        try {
            Object.defineProperty(target, "geolocation", { configurable: true, value: shim });
            installed = true;
        } catch (_) {
            // Some hardened runtimes mark one of the two non-configurable; the other still takes the shim.
        }
    }
    window.__kiwixGeolocationShimInstalled = installed;
})();
