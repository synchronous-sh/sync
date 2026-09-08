const year = document.getElementById("year");
if (year) year.textContent = String(new Date().getFullYear());

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function setNote(form, message, isError) {
  const note = form.querySelector(".form-note");
  if (!note) return;
  note.textContent = message;
  note.classList.toggle("error", Boolean(isError));
}

async function submitWaitlist(email, source) {
  const response = await fetch("/api/waitlist", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, source, referrer: document.referrer || "" }),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || "Could not join the waitlist.");
  }
  return payload;
}

document.querySelectorAll("form.waitlist").forEach((form) => {
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const input = form.querySelector("input[type=email]");
    const button = form.querySelector("button");
    const email = (input?.value || "").trim().toLowerCase();
    if (!emailPattern.test(email)) {
      setNote(form, "Enter a valid email address.", true);
      input?.focus();
      return;
    }
    button.disabled = true;
    setNote(form, "Joining…", false);
    try {
      await submitWaitlist(email, form.dataset.form || "unknown");
      setNote(form, "You’re on the list. We’ll write when TestFlight opens.", false);
      form.reset();
    } catch (error) {
      setNote(form, error.message || "Something went wrong. Try again.", true);
    } finally {
      button.disabled = false;
    }
  });
});
