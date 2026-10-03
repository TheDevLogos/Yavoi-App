// The public website stays universal. Android release builds set this value so
// each store application exposes only the account type it was created for.
export const appTarget = import.meta.env.VITE_YAVOI_APP_TARGET || "universal";
export const targetRole = appTarget === "driver" ? "driver" : appTarget === "passenger" ? "passenger" : "";
export const isNativeApp = () => Boolean(window.Capacitor?.isNativePlatform?.());
export const appTargetName = () => targetRole === "driver" ? "Yavoi! Conductor" : targetRole === "passenger" ? "Yavoi! Pasajero" : "Yavoi!";
export const targetAllowsRole = (role) => !targetRole || role === targetRole;
