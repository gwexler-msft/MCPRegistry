// Set up event handlers
const reconnectModal = document.getElementById("components-reconnect-modal");
reconnectModal.addEventListener("components-reconnect-state-changed", handleReconnectStateChanged);

const retryButton = document.getElementById("components-reconnect-button");
retryButton.addEventListener("click", retry);

const resumeButton = document.getElementById("components-resume-button");
resumeButton.addEventListener("click", resume);

function reportReconnectDiagnostic(kind, details) {
    if (typeof window.reportClientDiagnostic === "function") {
        window.reportClientDiagnostic(kind, details);
    }
}

function handleReconnectStateChanged(event) {
    reportReconnectDiagnostic("reconnect-state", {
        state: event.detail.state
    });

    if (event.detail.state === "show") {
        reconnectModal.showModal();
    } else if (event.detail.state === "hide") {
        reconnectModal.close();
    } else if (event.detail.state === "failed") {
        document.addEventListener("visibilitychange", retryWhenDocumentBecomesVisible);
    } else if (event.detail.state === "rejected") {
        reportReconnectDiagnostic("reconnect-rejected-reload", {
            reason: "state-rejected"
        });
        location.reload();
    }
}

async function retry() {
    document.removeEventListener("visibilitychange", retryWhenDocumentBecomesVisible);

    try {
        // Reconnect will asynchronously return:
        // - true to mean success
        // - false to mean we reached the server, but it rejected the connection (e.g., unknown circuit ID)
        // - exception to mean we didn't reach the server (this can be sync or async)
        const successful = await Blazor.reconnect();
        reportReconnectDiagnostic("reconnect-attempt", {
            successful
        });
        if (!successful) {
            // We have been able to reach the server, but the circuit is no longer available.
            // We'll reload the page so the user can continue using the app as quickly as possible.
            const resumeSuccessful = await Blazor.resumeCircuit();
            reportReconnectDiagnostic("resume-attempt", {
                resumeSuccessful
            });
            if (!resumeSuccessful) {
                reportReconnectDiagnostic("resume-failed-reload", {
                    reason: "resume-returned-false"
                });
                location.reload();
            } else {
                reconnectModal.close();
            }
        }
    } catch (err) {
        // We got an exception, server is currently unavailable
        reportReconnectDiagnostic("reconnect-exception", {
            message: err?.message ?? String(err ?? "")
        });
        document.addEventListener("visibilitychange", retryWhenDocumentBecomesVisible);
    }
}

async function resume() {
    try {
        const successful = await Blazor.resumeCircuit();
        reportReconnectDiagnostic("manual-resume-attempt", {
            successful
        });
        if (!successful) {
            reportReconnectDiagnostic("manual-resume-reload", {
                reason: "manual-resume-returned-false"
            });
            location.reload();
        }
    } catch {
        reportReconnectDiagnostic("manual-resume-exception", {
            reason: "exception"
        });
        reconnectModal.classList.replace("components-reconnect-paused", "components-reconnect-resume-failed");
    }
}

async function retryWhenDocumentBecomesVisible() {
    if (document.visibilityState === "visible") {
        await retry();
    }
}
