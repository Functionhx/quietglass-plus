// QuietGlass Plus — project page. No build step, no dependencies (MediaPipe loads
// only if you start the live demo). Animations pause when off screen.
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ---------------- i18n ---------------- */
const EN = {
  "nav.story": "How it works", "nav.styles": "Covers", "nav.power": "Power", "nav.earbuds": "Earbuds", "nav.try": "Try it", "nav.install": "Install",
  "hero.eyebrow": "Privacy screen for macOS · Apple silicon · fully on-device",
  "hero.title1": "Only you,", "hero.title2": "see it clearly.",
  "hero.sub": "Step away and your screen is covered on the very first frame, then the camera switches off. Come back within a minute and press any key; later, Touch ID. Recognition runs on the Neural Engine in 0.85 ms.",
  "hero.try": "Try it in your browser", "hero.install": "Install on your Mac",
  "strip.ane": "per face recognition on the Neural Engine", "strip.fpsUnit": "/s", "strip.detect": "face checks per second in away mode",
  "strip.cameraOff": "camera use while you're away — it's off", "strip.faces": "faces", "strip.facesNote": "you can save, like Face ID",
  "story.eyebrow": "What happens when you step away",
  "story.s0t": "You're at your Mac", "story.s0p": "The camera glances twice a second: is there a face? No identity, no screen recording, nothing uploaded.",
  "story.s1t": "You get up", "story.s1p": "Only 5 seconds without a face counts as leaving. Checking your phone or turning to talk won't trigger it.",
  "story.s2t": "Covered on frame one", "story.s2p": "Frosted instantly, then a privacy sheet unfolds like a folding phone. The animation always plays over an already hidden screen.",
  "story.s3t": "The camera turns off", "story.s3p": "Nobody needs to watch an empty chair. However long you're away, that's how long the camera rests.",
  "story.s4t": "Black after 15 seconds", "story.s4p": "Live frosted glass keeps the system computing blur. With nobody watching, it simply goes black.",
  "story.s5t": "Back? Press any key", "story.s5p": "Within a minute any key folds the sheet back into a line of light; after that, Touch ID. A stranger mashing keys gets nowhere.",
  "story.camOff": "Camera off",
  "styles.eyebrow": "Four covers", "styles.title": "Hide first. Then dazzle.", "styles.sub": "Every style is opaque from its first frame. Click a card to watch it cover the screen.",
  "styles.fold": "Fold", "styles.foldP": "Two smoked-glass halves unfold from a center hinge, like a folding phone.",
  "styles.curtain": "Curtain", "styles.curtainP": "Pleated velvet springs closed from both sides.",
  "styles.frosted": "Frosted", "styles.frostedP": "System frosted glass composited by WindowServer. Lowest power.",
  "styles.black": "Black", "styles.blackP": "The most direct — and where every style ends after 15 seconds away.",
  "power.eyebrow": "Measured · MacBook Air M4", "power.title": "The camera is what costs power.",
  "power.sub": "The AI itself is cheap: a small model on a dedicated chip. So the work went into opening the camera less, waking less, and drawing less.",
  "power.fps": "Camera frame rate", "power.fpsNote": "Upstream asked for 10 fps; the 15–30 fps camera rejected it",
  "power.cam": "System camera process CPU", "power.sface": "One face recognition", "power.sfaceNote": "CPU → Neural Engine, embedding cosine > 0.999",
  "power.rec": "Background screen recording", "power.recNote": "Upstream recorded the screen at full resolution while monitoring",
  "power.idle": "App CPU while head tracking", "power.idleNote": "No longer redraws the UI on every sample",
  "faces.eyebrow": "Like Face ID", "faces.title": "Save yourself, and the people you trust.",
  "faces.sub": "Up to 5 faces: you, you with glasses, family. Saved people sitting beside you aren't onlookers. Faces are kept only as 128-number templates in your Mac's Keychain — never photos.",
  "faces.glasses": "Me with glasses", "faces.family": "Family",
  "faces.t1": "SFace recognition on Apple's Neural Engine", "faces.t2": "Unlock your Mac and the screen is clear — no second Touch ID", "faces.t3": "Optional head turn so a photo won't pass",
  "ear.eyebrow": "Not just AirPods", "ear.title": "Your earbuds are a sensor too.",
  "ear.sub": "Sony WF-1000XM6 exposes Android's standard head-tracker protocol over Bluetooth HID. We read it 25 times a second; turn your head and the screen covers — no camera needed.",
  "ear.state": "Screen", "ear.clear": "Clear", "ear.cover": "Covered",
  "ear.note": "A replay of real WF-1000XM6 data, after reference stitching, the 12 s warm-up and compensation for the earbud's 45° tilt.",
  "try.eyebrow": "Live demo", "try.title": "Step away now. Really.", "try.sub": "With your camera on, face detection runs locally in your browser. Leave for 3 seconds and the screen below covers itself; come back and press Esc.",
  "try.placeholder": "Camera off", "try.idle": "Ready", "try.start": "Turn on camera", "try.sim": "No camera? Simulate leaving",
  "try.privacy": "Video never leaves your browser. The model comes from Google MediaPipe (~1 MB, first load). Closing the page stops everything.",
  "honest.title": "And honestly:", "honest.h1": "A cover isn't a lock", "honest.p1": "If the app crashes the cover disappears, and other apps can still read the screen. For longer absences, let it lock your Mac.",
  "honest.h2": "A webcam isn't Face ID", "honest.p2": "An RGB camera can't prove liveness. The head-turn check only raises the bar — which is why away mode unlocks with Touch ID.",
  "honest.h3": "It only sees the frame", "honest.p3": "People outside the camera's view are invisible to it. In a café, a better seat beats any algorithm.",
  "install.eyebrow": "Open source · MIT", "install.title": "Three commands to your Mac.", "install.copy": "Copy",
  "install.after": "Then: Settings → Protection → turn on camera protection. The default is “cover when I leave, unlock by keyboard”.",
  "install.github": "View on GitHub",
  "footer.credit": "Built on <a href=\"https://github.com/clintonimaroo/quietglass\">QuietGlass</a> by Clinton Imaro · SFace model Apache 2.0 · MIT License",
  "footer.bug": "Found a bug? Tell us →",
  "footer.power": "This page saves power too: off-screen animations pause, and Reduce Motion is respected.",
  // dynamic
  "cap.fold": "Fold", "cap.curtain": "Curtain", "cap.frosted": "Frosted", "cap.black": "Black",
  "badge.title": "Privacy protected", "badge.away": "You stepped away", "badge.esc": "Press Esc to unlock", "badge.touch": "Unlock with Touch ID",
  "try.loading": "Loading face detection…", "try.watching": "Watching · leave for 3 s", "try.seen": "Face detected · screen clear",
  "try.leaving": "No face · covering in {s} s", "try.covered": "Covered · camera off · press Esc", "try.denied": "Camera unavailable — try “Simulate leaving”",
  "try.failed": "Couldn't load the model — try “Simulate leaving”", "try.simCovered": "Simulated: covered · press Esc", "try.unlock": "Press Esc (or tap here) to unlock",
};
const ZH = {
  "cap.fold": "折叠", "cap.curtain": "幕布", "cap.frosted": "磨砂", "cap.black": "纯黑",
  "badge.title": "隐私保护中", "badge.away": "你已离开", "badge.esc": "按 Esc 解锁", "badge.touch": "用 Touch ID 解锁",
  "try.loading": "正在加载人脸检测…", "try.watching": "检测中 · 离开 3 秒试试", "try.seen": "检测到人脸 · 屏幕清晰",
  "try.leaving": "没有人脸 · {s} 秒后遮挡", "try.covered": "已遮挡 · 摄像头已关闭 · 按 Esc 解锁", "try.denied": "摄像头不可用，试试“模拟离开”",
  "try.failed": "模型加载失败，试试“模拟离开”", "try.simCovered": "模拟：已遮挡 · 按 Esc 解锁", "try.unlock": "按 Esc（或点这里）解锁",
};
let lang = localStorage.getItem("qg-lang") || (navigator.language.startsWith("zh") ? "zh" : "en");
const t = (key, vars = {}) => {
  let s = (lang === "en" ? EN[key] : ZH[key]) ?? key;
  for (const [k, v] of Object.entries(vars)) s = s.replace(`{${k}}`, v);
  return s;
};
function applyLanguage() {
  document.documentElement.lang = lang === "en" ? "en" : "zh-Hans";
  for (const el of $$("[data-i18n]")) {
    if (el.dataset.zh === undefined) el.dataset.zh = el.innerHTML;
    const key = el.dataset.i18n;
    el.innerHTML = lang === "en" && EN[key] ? EN[key] : el.dataset.zh;
  }
  $("#lang").textContent = lang === "en" ? "中文" : "EN";
  for (const s of screens) s.localize();
  document.dispatchEvent(new Event("languagechange-qg"));
}
$("#lang").addEventListener("click", () => {
  lang = lang === "en" ? "zh" : "en";
  localStorage.setItem("qg-lang", lang);
  applyLanguage();
});

/* ---------------- theme ---------------- */
const SUN = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="12" r="4.2"/><path d="M12 2v2.2M12 19.8V22M4.9 4.9l1.6 1.6M17.5 17.5l1.6 1.6M2 12h2.2M19.8 12H22M4.9 19.1l1.6-1.6M17.5 6.5l1.6-1.6"/></svg>`;
const MOON = `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20.5 14.6A8.5 8.5 0 0 1 9.4 3.5a8.5 8.5 0 1 0 11.1 11.1Z"/></svg>`;
const isLight = () => document.documentElement.dataset.theme === "light";
function paintThemeButton() { $("#theme").innerHTML = isLight() ? MOON : SUN; }
$("#theme").addEventListener("click", () => {
  document.documentElement.dataset.theme = isLight() ? "dark" : "light";
  localStorage.setItem("qg-theme", document.documentElement.dataset.theme);
  paintThemeButton();
});
matchMedia("(prefers-color-scheme: light)").addEventListener("change", (e) => {
  if (localStorage.getItem("qg-theme")) return;   // an explicit choice wins
  document.documentElement.dataset.theme = e.matches ? "light" : "dark";
  paintThemeButton();
});
paintThemeButton();

/* ---------------- visibility helper: pause work off screen ---------------- */
function whenVisible(el, onChange, threshold = 0) {
  const io = new IntersectionObserver((entries) => entries.forEach((e) => onChange(e.isIntersecting)), { threshold });
  io.observe(el);
}

/* ---------------- aurora (WebGL) ---------------- */
(function aurora() {
  const canvas = $("#aurora");
  const gl = canvas.getContext("webgl", { antialias: false, premultipliedAlpha: false });
  if (!gl) return;
  const vs = `attribute vec2 p; void main(){ gl_Position = vec4(p, 0., 1.); }`;
  const fs = `precision mediump float;
  uniform vec2 r; uniform float t; uniform vec2 m; uniform float s; uniform float L;
  float h(vec2 p){ return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453); }
  float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.-2.*f);
    return mix(mix(h(i), h(i+vec2(1,0)), f.x), mix(h(i+vec2(0,1)), h(i+vec2(1,1)), f.x), f.y); }
  float fbm(vec2 p){ float v = 0., a = .5; for (int i = 0; i < 5; i++){ v += a*n(p); p = p*2.03 + vec2(1.7, 9.2); a *= .5; } return v; }
  void main(){
    vec2 uv = gl_FragCoord.xy / r; vec2 p = (gl_FragCoord.xy - .5*r) / r.y;
    float tt = t * .045;
    vec2 q = vec2(fbm(p*1.3 + tt), fbm(p*1.3 - tt + 4.));
    float f = fbm(p*1.8 + 2.2*q + vec2(tt*1.6, -tt) + m*.35);
    vec3 pink = vec3(.94,.68,.91), violet = vec3(.55,.42,.98), cyan = vec3(.35,.75,.98), deep = vec3(.02,.025,.045);
    vec3 col = mix(violet, pink, smoothstep(.35, .85, f));
    col = mix(col, cyan, smoothstep(.55, .95, q.y));
    float band = smoothstep(.15, .9, f) * smoothstep(1.25, .1, abs(p.y + .25 - .35*sin(p.x*1.6 + tt*3.)));
    float glow = band * (.55 + .45*fbm(p*3. - tt*2.));
    float fade = mix(.95, .25, clamp(s, 0., 1.));      // dimmer as you scroll
    vec3 c = deep + col * glow * .55 * fade;
    c += .04 * vec3(.6,.5,1.) * smoothstep(1.2, 0., length(p - vec2(m.x*.4, .45)));
    vec3 dark = c * (1. - .35*length(uv - .5));
    // daylight: pastel light washing over warm paper
    vec3 paper = vec3(.968, .965, .985);
    vec3 day = mix(paper, col*.9 + .1, glow * .42 * mix(1., .55, clamp(s, 0., 1.)));
    day += .03 * vec3(1., .85, .95) * smoothstep(1.2, 0., length(p - vec2(m.x*.4, .45)));
    gl_FragColor = vec4(mix(dark, day, L), 1.);
  }`;
  const prog = gl.createProgram();
  for (const [type, src] of [[gl.VERTEX_SHADER, vs], [gl.FRAGMENT_SHADER, fs]]) {
    const sh = gl.createShader(type); gl.shaderSource(sh, src); gl.compileShader(sh); gl.attachShader(prog, sh);
  }
  gl.linkProgram(prog); gl.useProgram(prog);
  const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, "p"); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  const uR = gl.getUniformLocation(prog, "r"), uT = gl.getUniformLocation(prog, "t"), uM = gl.getUniformLocation(prog, "m"), uS = gl.getUniformLocation(prog, "s"), uL = gl.getUniformLocation(prog, "L");
  let light = isLight() ? 1 : 0;
  const scale = 0.5; // render at half resolution: it's a soft gradient anyway
  const resize = () => { canvas.width = innerWidth * scale; canvas.height = innerHeight * scale; gl.viewport(0, 0, canvas.width, canvas.height); };
  resize(); addEventListener("resize", resize);
  let mouse = [0, 0], target = [0, 0];
  addEventListener("pointermove", (e) => { target = [e.clientX / innerWidth - .5, .5 - e.clientY / innerHeight]; });
  let last = 0, running = true;
  document.addEventListener("visibilitychange", () => { running = !document.hidden; if (running) requestAnimationFrame(frame); });
  function frame(now) {
    if (!running) return;
    // ~30 fps is plenty for a slow gradient
    if (now - last > 33) {
      last = now;
      mouse = mouse.map((v, i) => v + (target[i] - v) * .04);
      gl.uniform2f(uR, canvas.width, canvas.height);
      gl.uniform1f(uT, reduceMotion ? 20 : now / 1000);
      gl.uniform2f(uM, mouse[0], mouse[1]);
      gl.uniform1f(uS, scrollY / (innerHeight * 3));
      light += ((isLight() ? 1 : 0) - light) * .08;   // cross-fade when the theme changes
      gl.uniform1f(uL, light);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    if (!reduceMotion) requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();

/* ---------------- fake desktop + cover ---------------- */
const LOCK = `<svg class="lock" viewBox="0 0 24 24" fill="#fff"><path d="M7 10V7a5 5 0 0 1 10 0v3h1a1 1 0 0 1 1 1v9a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1h1Zm2 0h6V7a3 3 0 0 0-6 0v3Z"/></svg>`;
function desktopHTML(mini) {
  const dock = ["#ff6b6b", "#ffd166", "#06d6a0", "#4cc9f0", "#a78bfa", "#f0aee8"].map((c) => `<i style="background:linear-gradient(135deg,${c},#222)"></i>`).join("");
  return `<div class="desktop">
    <div class="menubar"><b></b><b>Messages</b><span>File</span><span>Edit</span><span>View</span><span class="right">${mini ? "" : "Sat 14:42"}</span></div>
    <div class="win chat"><div class="bar"><i></i><i></i><i></i><span>Messages</span></div><div class="msgs">
      <div class="m">offer 下来了吗？</div><div class="m me">下来了！年薪 ¥680,000 🎉</div><div class="m">先别告诉别人</div><div class="m me">银行卡尾号 4721，密码我改了</div></div></div>
    <div class="win code"><div class="bar"><i></i><i></i><i></i><span>secrets.swift</span></div><pre><span class="cm">// production credentials</span>
<span class="k">let</span> apiKey = <span class="s">"sk-proj-9fQ2…x7Lm"</span>
<span class="k">let</span> dbPassword = <span class="s">"hunter2-Ä8!"</span>
<span class="k">func</span> <span class="f">transfer</span>(amount: <span class="k">Int</span>) {
  bank.<span class="f">send</span>(amount, to: <span class="s">"6222 0213 4567 4721"</span>)
}</pre></div>
    <div class="win card"><span class="chipx"></span><span class="num">6222 •••• •••• 4721</span></div>
    <div class="dock">${dock}</div></div>`;
}
const screens = [];
class Screen {
  constructor(el, { mini = false, away = false, escHint = false } = {}) {
    this.el = el; this.away = away; this.escHint = escHint;
    el.innerHTML = desktopHTML(mini) + `<div class="cover"><div class="frost"></div><div class="stage"><div class="sheet l"></div><div class="sheet r"></div><div class="hinge"></div></div><div class="dim"></div>
      <div class="badge">${LOCK}<b></b><span></span>${mini ? "" : "<em></em>"}</div></div>`;
    this.style = "fold"; this.state = "clear"; this.timers = [];
    this.setStyle("fold"); this.localize();
    screens.push(this);
  }
  localize() {
    const b = $(".badge b", this.el), s = $(".badge span", this.el), em = $(".badge em", this.el);
    b.textContent = t("badge.title");
    s.textContent = this.away ? t("badge.away") : t("cap." + this.style);
    if (em) em.textContent = this.away && !this.escHint ? t("badge.touch") : t("badge.esc");
  }
  clearTimers() { this.timers.forEach(clearTimeout); this.timers = []; }
  setStyle(style) {
    this.el.classList.remove("style-fold", "style-curtain", "style-frosted", "style-black");
    this.el.classList.add("style-" + style); this.style = style; this.localize();
  }
  cover(style = this.style) {
    if (this.state === "covered" && style === this.style) return;
    this.clearTimers();
    this.el.classList.remove("covered", "revealing", "to-black");
    this.setStyle(style);
    void this.el.offsetWidth;            // start from the folded / offstage pose
    this.el.classList.add("covered");    // frost is opaque immediately; sheets animate over it
    this.state = "covered";
  }
  toBlack() { if (this.state === "covered") this.el.classList.add("to-black"); }
  reveal() {
    if (this.state !== "covered") return;
    this.clearTimers();
    this.el.classList.add("revealing");
    this.state = "revealing";
    this.timers.push(setTimeout(() => {
      this.el.classList.remove("covered", "revealing", "to-black");
      this.state = "clear";
    }, 750));
  }
}

/* ---------------- hero ---------------- */
const hero = new Screen($("#heroScreen"));
(function heroLoop() {
  const styles = ["fold", "curtain", "frosted"];
  const caption = $("#heroCaptionText");
  let i = 0, visible = true, running = false;
  const setCaption = () => { caption.textContent = t("cap." + styles[i % styles.length]); };
  document.addEventListener("languagechange-qg", setCaption);
  async function loop() {
    if (running) return; running = true;
    while (visible && !reduceMotion) {
      const style = styles[i % styles.length]; setCaption();
      await sleep(1600); if (!visible) break;
      hero.cover(style);
      await sleep(2800);
      hero.reveal();
      await sleep(1400);
      i++;
    }
    running = false;
  }
  whenVisible($("#heroStage"), (v) => { visible = v; if (v) loop(); });
  setCaption();
  // parallax tilt
  const laptop = $("#heroLaptop");
  addEventListener("pointermove", (e) => {
    if (reduceMotion) return;
    const x = e.clientX / innerWidth - .5, y = e.clientY / innerHeight - .5;
    laptop.style.setProperty("--tilt-y", `${x * 10}deg`);
    laptop.style.setProperty("--tilt-x", `${8 + y * 6}deg`);
  });
})();

/* ---------------- story (scroll-driven) ---------------- */
(function story() {
  const section = $("#story"), steps = $$("#steps li");
  const screen = new Screen($("#storyScreen"), { away: true });
  const led = $("#storyLed"), person = $("#vfPerson"), box = $("#vfBox"), ring = $("#vfRing"), count = $("#vfCount");
  const arc = $("#vfRing .arc"), off = $("#vfOff"), keys = $("#keys"), label = $("#vfLabel");
  const mobile = () => innerWidth <= 960;
  let lastStep = -1;
  function update() {
    if (mobile()) return;
    const rect = section.getBoundingClientRect();
    const total = section.offsetHeight - innerHeight;
    const p = Math.min(1, Math.max(0, -rect.top / total));
    const raw = p * 6, step = Math.min(5, Math.floor(raw)), sub = raw - step;
    if (step !== lastStep) { steps.forEach((li, i) => li.classList.toggle("active", i === step)); lastStep = step; }
    // camera LED + viewfinder
    const camOn = step <= 2 || step === 5;
    led.classList.toggle("on", camOn);
    off.style.opacity = camOn ? 0 : 1;
    label.textContent = camOn ? "CAMERA · 2 fps · detect only" : "CAMERA · OFF";
    let shift = 0;
    if (step === 1) shift = Math.min(1, sub * 1.6);
    if (step >= 2 && step <= 4) shift = 1;
    if (step === 5) shift = Math.max(0, 1 - sub * 2.2);
    person.style.transform = `translateX(${shift * 130}%)`;
    box.style.opacity = shift < .35 ? 1 : 0;
    box.style.left = `${35 + shift * 40}%`;
    ring.style.opacity = step === 1 ? 1 : 0;
    const remaining = Math.max(0, 5 - sub * 5);
    count.textContent = Math.ceil(remaining);
    arc.style.strokeDashoffset = `${119.4 * (1 - remaining / 5)}`;
    keys.style.opacity = step === 5 && sub > .3 && sub < .8 ? 1 : 0;
    keys.classList.toggle("press", step === 5 && sub > .4);
    keys.classList.toggle("auth", step === 5 && sub > .55);
    // screen
    if (step >= 2 && !(step === 5 && sub > .65)) {
      screen.cover("fold");
      if (step >= 4) screen.toBlack(); else screen.el.classList.remove("to-black");
    } else screen.reveal();
  }
  let ticking = false;
  addEventListener("scroll", () => { if (!ticking) { ticking = true; requestAnimationFrame(() => { ticking = false; update(); }); } }, { passive: true });
  addEventListener("resize", update);
  if (mobile()) { steps.forEach((li) => li.classList.add("active")); led.classList.add("on"); }
  update();
})();

/* ---------------- style cards ---------------- */
for (const card of $$(".style-card")) {
  const screen = new Screen($(".screen", card), { mini: true });
  const style = card.dataset.style;
  screen.setStyle(style);
  const play = async () => { screen.cover(style); await sleep(1900); screen.reveal(); };
  card.addEventListener("click", play);
  let played = false;
  whenVisible(card, (v) => { if (v && !played) { played = true; setTimeout(play, 300 + 250 * $$(".style-card").indexOf(card)); } }, .6);
}

/* ---------------- count-ups, bars, reveal, spotlight ---------------- */
const countUp = (el) => {
  const target = parseFloat(el.dataset.count), dec = +(el.dataset.decimals || 0), start = performance.now(), dur = 1400;
  const step = (now) => {
    const k = Math.min(1, (now - start) / dur), e = 1 - Math.pow(1 - k, 3);
    el.textContent = (target * e).toFixed(dec);
    if (k < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
};
const io = new IntersectionObserver((entries) => {
  for (const e of entries) {
    if (!e.isIntersecting) continue;
    e.target.classList.add("in");
    $$("[data-count]", e.target).forEach(countUp);
    if (e.target.id === "powerTable") fillBars();
    io.unobserve(e.target);
  }
}, { threshold: .18 });
$$(".reveal").forEach((el) => io.observe(el));
function fillBars() {
  $$(".power-row").forEach((row, i) => {
    const { before, after, max, unit } = row.dataset, dec = +(row.dataset.decimals || 0);
    setTimeout(() => {
      $(".before", row).style.width = `${(before / max) * 100}%`;
      $(".after", row).style.width = `${Math.max(1.2, (after / max) * 100)}%`;
    }, 150 * i);
    const fmt = (v) => (+v).toFixed(dec === 0 && Number.isInteger(+v) ? 0 : dec || 1);
    $(".pr-val", row).innerHTML = `<s>${fmt(before)}</s>→ <b>${fmt(after)}</b> ${unit}`;
  });
  $$(".legend i").forEach((i) => (i.style.width = "22px"));
}
for (const el of $$(".spot")) {
  el.addEventListener("pointermove", (e) => {
    const r = el.getBoundingClientRect();
    el.style.setProperty("--mx", `${e.clientX - r.left}px`);
    el.style.setProperty("--my", `${e.clientY - r.top}px`);
  });
}
$("#copy").addEventListener("click", async () => {
  await navigator.clipboard.writeText($("#code").innerText.split("\n").filter((l) => !l.startsWith("#")).join("\n"));
  $("#copy").textContent = lang === "en" ? "Copied" : "已复制";
  setTimeout(() => ($("#copy").textContent = lang === "en" ? "Copy" : "复制"), 1600);
});

/* ---------------- face point cloud ---------------- */
function facePoints() {
  // A parametric head: an ellipsoid with a nose ridge, brow, eye sockets and chin.
  const pts = [];
  for (let i = 0; i <= 26; i++) {
    const v = -Math.PI / 2 + (i / 26) * Math.PI;
    for (let j = 0; j <= 34; j++) {
      const u = -Math.PI * .62 + (j / 34) * Math.PI * 1.24;
      let x = Math.cos(v) * Math.sin(u) * .78, y = Math.sin(v) * 1.08, z = Math.cos(v) * Math.cos(u) * .9;
      const gx = x, gy = y;
      z += .26 * Math.exp(-((gx / .09) ** 2) - (((gy + .02) / .32) ** 2));        // nose
      z -= .12 * Math.exp(-(((Math.abs(gx) - .3) / .14) ** 2) - (((gy - .2) / .09) ** 2)); // eye sockets
      z += .06 * Math.exp(-(((gy - .36) / .08) ** 2)) * (Math.abs(gx) < .5);       // brow
      y -= .08 * Math.exp(-((gx / .3) ** 2)) * (gy < -.6);                          // chin
      x *= 1 - .18 * Math.max(0, -gy - .4);                                          // jaw taper
      pts.push({ x, y: -y, z, row: i, col: j, front: Math.cos(u) > .2 });
    }
  }
  return pts;
}
const FACE = facePoints();
function drawHead(ctx, size, yaw, pitch, opts = {}) {
  const { glow = 1, earbud = false, hot = false } = opts;
  ctx.clearRect(0, 0, size, size);
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  const proj = FACE.map((p) => {
    let x = p.x * cy + p.z * sy, z = -p.x * sy + p.z * cy, y = p.y;
    const y2 = y * cp - z * sp; z = y * sp + z * cp; y = y2;
    const f = 2.6 / (3.2 - z);
    return { X: size / 2 + x * f * size * .28, Y: size / 2 + y * f * size * .28, z, p };
  });
  const cols = 35;
  ctx.lineWidth = 1;
  for (let k = 0; k < proj.length; k++) {
    const a = proj[k];
    for (const n of [k + 1, k + cols]) {
      const b = proj[n];
      if (!b || (n === k + 1 && b.p.row !== a.p.row)) continue;
      const depth = (a.z + b.z) / 2;
      if (depth < -.05) continue;
      ctx.strokeStyle = `rgba(${hot ? (isLight() ? "192,79,182" : "240,174,232") : (isLight() ? "109,63,184" : "167,139,250")},${(.05 + .22 * depth) * glow * (isLight() ? 1.6 : 1)})`;
      ctx.beginPath(); ctx.moveTo(a.X, a.Y); ctx.lineTo(b.X, b.Y); ctx.stroke();
    }
  }
  for (const a of proj) {
    if (a.z < -.05) continue;
    const r = .6 + 1.6 * Math.max(0, a.z);
    ctx.fillStyle = a.p.front ? (isLight() ? `rgba(192,79,182,${(.35 + .6 * a.z) * glow})` : `rgba(240,174,232,${(.25 + .6 * a.z) * glow})`)
      : (isLight() ? `rgba(31,155,214,${(.25 + .5 * a.z) * glow})` : `rgba(125,211,252,${(.15 + .4 * a.z) * glow})`);
    ctx.beginPath(); ctx.arc(a.X, a.Y, r, 0, 7); ctx.fill();
  }
  if (earbud) {
    // left earbud sits at the head's side; glow it
    const ex = -.8, ey = -.05, ez = -.05;
    let x = ex * cy + ez * sy, z = -ex * sy + ez * cy, y = ey;
    const y2 = y * cp - z * sp; z = y * sp + z * cp; y = y2;
    const f = 2.6 / (3.2 - z), X = size / 2 + x * f * size * .28, Y = size / 2 + y * f * size * .28;
    const g = ctx.createRadialGradient(X, Y, 0, X, Y, 26);
    g.addColorStop(0, "rgba(255,255,255,.95)"); g.addColorStop(.3, "rgba(125,211,252,.7)"); g.addColorStop(1, "rgba(125,211,252,0)");
    ctx.fillStyle = g; ctx.beginPath(); ctx.arc(X, Y, 26, 0, 7); ctx.fill();
  }
}
(function faceMesh() {
  const canvas = $("#faceMesh"), ctx = canvas.getContext("2d");
  let visible = false;
  whenVisible(canvas, (v) => { visible = v; if (v) requestAnimationFrame(frame); });
  function frame(now) {
    if (!visible) return;
    drawHead(ctx, canvas.width, Math.sin(now / 2600) * .65, Math.sin(now / 3900) * .12);
    if (!reduceMotion) requestAnimationFrame(frame);
  }
})();

/* ---------------- earbuds: replay of real WF-1000XM6 data ---------------- */
// [seconds, yaw°, pitch°] from a `--headphone-check` run after the 12 s warm-up,
// re-centered on the resting pose. A right turn, then looking down at the keyboard.
const REPLAY = [
  [0, 0, 0], [.5, -.1, .5], [1, 0, .2], [1.5, 0, 0], [2, 0, 0], [3, 0, 0], [3.7, -.6, 1], [4.2, -.4, .4],
  [4.7, -40.8, -9.5], [5.3, -50.3, -4.5], [5.8, -49.5, -3.5], [6.3, -57.8, .9], [6.8, -52.2, 1.8], [7.3, -52.2, 1.2],
  [7.9, -52.9, 1.4], [8.4, -53.6, .5], [8.9, -53.3, .3], [9.4, -52.9, .6], [10, 1.2, -7.3], [10.5, -.4, -5.5],
  [11.1, -2.5, -6], [12.1, -2.3, -6.1], [13.1, -1.3, -3.5], [13.7, -.5, -2.9], [14.7, -.5, -2.8], [15.2, -.5, -16.7],
  [15.8, 1.9, -20.1], [16.3, 4.2, -20.3], [16.8, 4.6, -20.2], [17.4, 1.9, -19], [17.9, 1.1, -18.5], [18.4, -3, -18.8],
  [18.9, -2.4, -18.3], [19.4, .4, -17.1], [20, 1.8, -17.6], [20.5, -1.6, -2.4], [21, -.9, .9], [22, -.9, .5], [23.6, -.3, -.2], [25, 0, 0],
];
(function earbuds() {
  const canvas = $("#headCanvas"), ctx = canvas.getContext("2d");
  const yawEl = $("#yawVal"), pitchEl = $("#pitchVal"), state = $("#earState");
  let visible = false, t0 = 0, covered = false;
  const sample = (time) => {
    const T = REPLAY[REPLAY.length - 1][0], tt = time % T;
    let i = REPLAY.findIndex((r) => r[0] > tt); if (i <= 0) i = 1;
    const [ta, ya, pa] = REPLAY[i - 1], [tb, yb, pb] = REPLAY[i], k = (tt - ta) / (tb - ta);
    const e = k * k * (3 - 2 * k);
    return [ya + (yb - ya) * e, pa + (pb - pa) * e];
  };
  whenVisible(canvas, (v) => { visible = v; if (v) { t0 = performance.now(); requestAnimationFrame(frame); } });
  function frame(now) {
    if (!visible) return;
    const [yaw, pitch] = sample((now - t0) / 1000);
    const angle = Math.hypot(yaw, pitch);
    // same hysteresis as ShieldResponse: cover past 15°, clear under 12°
    if (!covered && angle > 15) covered = true; else if (covered && angle < 12) covered = false;
    drawHead(ctx, canvas.width, yaw * Math.PI / 180, -pitch * Math.PI / 180, { earbud: true, hot: covered });
    yawEl.textContent = `${yaw >= 0 ? "+" : ""}${yaw.toFixed(0)}°`;
    pitchEl.textContent = `${pitch >= 0 ? "+" : ""}${pitch.toFixed(0)}°`;
    state.textContent = covered ? t("ear.cover") : (lang === "en" ? EN["ear.clear"] : "清晰");
    state.className = covered ? "is-cover" : "is-clear";
    requestAnimationFrame(frame);
  }
})();
EN["ear.cover"] = "Covered"; ZH["ear.cover"] = "遮挡";

/* ---------------- live demo (MediaPipe, opt-in) ---------------- */
(function tryIt() {
  const screen = new Screen($("#tryScreen"), { away: true, escHint: true });
  const video = $("#tryVideo"), box = $("#tryBox"), status = $("#tryStatus"), led = $("#tryLed"), placeholder = $("#tryPlaceholder");
  let detector = null, stream = null, timer = null, lastFace = 0, covered = false;
  const setStatus = (key, vars) => { status.textContent = t(key, vars); status.dataset.key = key; };
  document.addEventListener("languagechange-qg", () => status.dataset.key && setStatus(status.dataset.key));

  async function loadDetector() {
    const vision = await import("https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14");
    const files = await vision.FilesetResolver.forVisionTasks("https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14/wasm");
    return vision.FaceDetector.createFromOptions(files, {
      baseOptions: { modelAssetPath: "https://storage.googleapis.com/mediapipe-models/face_detector/blaze_face_short_range/float16/1/blaze_face_short_range.tflite" },
      runningMode: "VIDEO", minDetectionConfidence: .5,
    });
  }
  async function startCamera() {
    stream = await navigator.mediaDevices.getUserMedia({ video: { width: 640, height: 480, frameRate: { max: 15 } }, audio: false });
    video.srcObject = stream; await video.play();
    placeholder.style.display = "none"; led.classList.add("on");
    lastFace = performance.now();
    // Like the app: a handful of checks per second is enough.
    timer = setInterval(check, 200);
  }
  function stopCamera() {
    clearInterval(timer); timer = null;
    stream?.getTracks().forEach((tr) => tr.stop()); stream = null;
    video.srcObject = null; placeholder.style.display = ""; led.classList.remove("on"); box.style.display = "none";
  }
  function check() {
    if (!detector || !stream || video.readyState < 2) return;
    const now = performance.now();
    const faces = detector.detectForVideo(video, now).detections;
    if (faces.length) {
      lastFace = now;
      const b = faces[0].boundingBox, w = video.videoWidth, h = video.videoHeight;
      Object.assign(box.style, { display: "block", left: `${(1 - (b.originX + b.width) / w) * 100}%`, top: `${(b.originY / h) * 100}%`, width: `${(b.width / w) * 100}%`, height: `${(b.height / h) * 100}%` });
      setStatus("try.seen");
    } else {
      box.style.display = "none";
      const left = Math.max(0, 3 - (now - lastFace) / 1000);
      setStatus("try.leaving", { s: left.toFixed(1) });
      if (left === 0) coverNow(false);
    }
  }
  function coverNow(simulated) {
    if (covered) return;
    covered = true;
    screen.cover("fold");
    stopCamera();                           // camera off while covered, as in the app
    setStatus(simulated ? "try.simCovered" : "try.covered");
    setTimeout(() => covered && screen.toBlack(), 15000);
  }
  async function unlock() {
    if (!covered) return;
    covered = false;
    screen.reveal();
    if (detector) { try { await startCamera(); setStatus("try.watching"); } catch { setStatus("try.denied"); } }
    else setStatus("try.idle");
  }
  $("#tryStart").addEventListener("click", async () => {
    if (stream) return;
    try {
      setStatus("try.loading");
      detector = detector || await loadDetector();
    } catch (e) { console.warn(e); setStatus("try.failed"); return; }
    try { await startCamera(); setStatus("try.watching"); } catch (e) { console.warn(e); setStatus("try.denied"); }
  });
  $("#trySim").addEventListener("click", () => coverNow(true));
  $("#tryScreen").addEventListener("click", unlock);
  addEventListener("keydown", (e) => { if (e.key === "Escape") unlock(); });
  addEventListener("pagehide", stopCamera);
})();

applyLanguage();
