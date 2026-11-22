// BU DOSYA ÜRETİLİR — elle düzenlemeyin. Kaynak: tv-tizen/ · Üreten: scripts/sync-tv-page.sh

enum TVPageAssets {
    static let indexHTML = #"""
<!DOCTYPE html>
<html lang="tr">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=1920, user-scalable=no">
    <title>Marhilk</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <!-- HDMI görüntüsü bu sayfanın ARKASINDA oynar; sayfa saydamdır. -->
    <!-- "Ekranı çevir": duraklatılmış ekrandaki yazıların çevirisi, kendi yerlerinde -->
    <!-- Görev/ipucu yazılarının çevirisi: oyun sürerken köşede, yerinde -->
    <div id="hud"></div>
    <div id="screen"></div>
    <div id="notice"></div>
    <!-- "Takıldım" yardımcısının ipucu kutusu -->
    <div id="help"></div>
    <!-- SARI tuş: kaçırılan son replikler -->
    <div id="recall"></div>
    <div id="subtitle" class="bottom" aria-live="polite"></div>
    <div id="panel">
        <div id="status">Başlatılıyor…</div>
        <div id="help">SARI son replikler · MAVİ ekrandaki her şeyi çevir · YEŞİL altyazıyı gizle/göster · ▲▼ yazının yeri · ◀▶ yazı boyutu · KIRMIZI HDMI değiştir · TAMAM bu paneli gizle · GERİ çıkış</div>
    </div>
    <script src="$WEBAPIS/webapis/webapis.js"></script>
    <script src="main.js"></script>
</body>
</html>

"""#

    static let mainJS = #"""
/* Marhilk — televizyon katmanı.
 *
 * Yaptığı iş: PS5'in HDMI görüntüsünü tam ekran olarak sayfanın ARKASINDA
 * gösterir, telefondan gelen Türkçe altyazıyı üstüne yazar.
 *
 * Üç ortamda çalışır:
 *   - Samsung (Tizen): kurulu uygulama; HDMI görüntüsü tizen.tvwindow ile gelir.
 *   - LG (webOS): TV'nin tarayıcısında, telefonun sunduğu sayfa olarak; HDMI görüntüsü
 *     webOS'un "dış giriş" video kaynağıyla gelir (LG'nin resmî belgelerinde yok, her modelde çalışmayabilir).
 *   - Bilgisayar tarayıcısı: önizleme.
 * Eski TV tarayıcıları için bilerek ES5 yazılmıştır.
 */
(function () {
    'use strict';

    // Bilgisayardaki önizlemede başka bir deneme sunucusuna bağlanabilmek için ?port= ile değiştirilebilir.
    var PORT = parseInt((/[?&]port=(\d+)/.exec(window.location.search) || [])[1], 10) || 8765;
    // Telefonun web sunucusu ("orada mısın?" sorusu buraya sorulur). Önizlemede ?http= ile değiştirilebilir.
    var HTTP_PORT = parseInt((/[?&]http=(\d+)/.exec(window.location.search) || [])[1], 10) || 8080;
    var SCAN_BATCH = 10;          // aynı anda sorulan adres sayısı (az: TV'nin bağlantı havuzu tıkanmasın)
    var SCAN_TIMEOUT_MS = 1000;
    // Bu TV uygulamasının sürümü. Telefona gömülürken (scripts/sync-tv-page.sh) dosyaların özetiyle
    // değiştirilir; telefon, televizyondaki sürüm kendi içindekinden farklıysa güncelleme önerir.
    var TV_BUILD = '931db9a22d61';
    // (Sürüm, telefon bağlanınca 'hello' iletisiyle bildirilir.)
    var BASE_FONT_VW = 1.35;      // 1080p'de ~26 piksel
    var SAFETY_CLEAR_MS = 15000;  // telefon "temizle" demese de yazı ekranda takılı kalmasın

    var onTV = typeof window.tizen !== 'undefined';
    var onWebOS = !onTV && /web0s|webos/i.test(window.navigator.userAgent);
    // Sayfayı telefon sunuyorsa (LG tarayıcısı) telefonun adresi zaten bellidir; ağ taranmaz.
    var servedByPhone = !onTV && /^http/.test(window.location.protocol) && !!window.location.hostname;
    // İkinci ekran: sayfa telefondan bir tablet, bilgisayar ya da eski telefonun tarayıcısında açılmış.
    // Arkada oyun görüntüsü yoktur; yazı siyah zeminde, uzaktan okunacak büyüklükte gösterilir.
    var secondScreen = servedByPhone && !onWebOS && !/[?&]bg=/.test(window.location.search);
    var hdmiVideo = null;
    var subtitleEl = document.getElementById('subtitle');
    var screenEl = document.getElementById('screen');
    var hudEl = document.getElementById('hud');
    var noticeEl = document.getElementById('notice');
    var noticeTimer = null;
    var screenShowing = false;
    var panelEl = document.getElementById('panel');
    var statusEl = document.getElementById('status');

    var socket = null;
    var failuresOnSavedHost = 0;
    var safetyTimer = null;
    var panelTimer = null;
    var hdmiSources = [];
    var hdmiIndex = 0;

    var style = {
        position: store('position') || 'bottom',
        scale: parseFloat(store('scale')) || 1,
        color: store('color') || '#ffffff',
        background: store('background') === null ? 0.62 : parseFloat(store('background')),
        bold: store('bold') === 'true',
        speakerColors: store('speakerColors') === 'true'
    };
    // Konuşan adlarının renkleri; telefondaki liste ile aynıdır (aynı ad iki tarafta aynı rengi alır).
    var SPEAKER_PALETTE = ['#ffd84d', '#7fd4ff', '#9be37f', '#ff9f7a', '#d7a6ff', '#ffb3d1'];

    function speakerColor(name) {
        if (!style.speakerColors) { return SPEAKER_PALETTE[0]; }
        var lower = String(name).toLowerCase();
        var hash = 0;
        for (var i = 0; i < lower.length; i++) { hash = (hash * 31 + lower.charCodeAt(i)) % 100003; }
        return SPEAKER_PALETTE[hash % SPEAKER_PALETTE.length];
    }

    function store(key, value) {
        try {
            if (value === undefined) { return window.localStorage.getItem('altyazitr.' + key); }
            window.localStorage.setItem('altyazitr.' + key, String(value));
        } catch (e) { /* depolama kapalıysa ayarlar kalıcı olmaz, çalışmaya devam */ }
        return null;
    }

    function setStatus(text, keepVisible) {
        statusEl.textContent = text;
        panelEl.className = '';
        clearTimeout(panelTimer);
        if (!keepVisible) {
            panelTimer = setTimeout(function () { panelEl.className = 'hidden'; }, 6000);
        }
    }

    // ---------- Altyazı ----------

    function applyStyle() {
        subtitleEl.className = style.position + (subtitleEl.firstChild ? ' visible' : '');
        subtitleEl.style.fontSize = ((secondScreen ? 3.1 : BASE_FONT_VW) * style.scale).toFixed(2) + 'vw';
        subtitleEl.style.color = style.color;
        subtitleEl.style.fontWeight = style.bold ? '700' : '500';
        var spans = subtitleEl.getElementsByTagName('span');
        for (var i = 0; i < spans.length; i++) { paint(spans[i]); }
    }

    /** Bir satırın zeminini ve konuşan rengini şimdiki görünüme göre boyar. */
    function paint(box) {
        box.style.background = 'rgba(0, 0, 0, ' + style.background.toFixed(2) + ')';
        // Zemin yokken yazı oyunun üstünde kaybolmasın: gölge koyulaşır.
        box.style.textShadow = style.background < 0.25 ? '0 0 0.12em #000, 0 0.06em 0.18em #000, 0 0 0.3em #000' : '0 0 0.1em #000';
        var who = box.getElementsByTagName('b')[0];
        if (who) { who.style.color = speakerColor(who.getAttribute('data-name') || ''); }
    }

    /**
     * Konuşma dökümü: her yeni replik en alta eklenir, öncekiler yukarı kayar, süresi dolan
     * silinerek çıkar. Satırlar kimlikleriyle izlenir; ekranda duran bir satır yeniden çizilmez,
     * yalnız metni değişirse (daha iyi çeviri geldiyse) güncellenir.
     */
    var rows = {};
    var recent = [];            // son replikler (SARI tuşla yeniden gösterilir)
    var recallEl = document.getElementById('recall');
    var recallTimer = null;

    /** Kaçırılan replikler için: son altı repliği sekiz saniyeliğine yeniden gösterir. */
    function toggleRecall() {
        clearTimeout(recallTimer);
        if (recallEl.className === 'visible') {
            recallEl.className = '';
            return;
        }
        while (recallEl.firstChild) { recallEl.removeChild(recallEl.firstChild); }
        if (!recent.length) {
            showNotice('Henüz replik yok.', 2500);
            return;
        }
        for (var i = 0; i < recent.length; i++) {
            var line = document.createElement('div');
            line.className = 'line';
            fillRow(line, recent[i].s, recent[i].t);
            recallEl.appendChild(line);
        }
        recallEl.className = 'visible';
        recallTimer = setTimeout(function () { recallEl.className = ''; }, 8000);
    }

    function fillRow(box, speaker, text, original) {
        var signature = (speaker || '') + '\u0001' + text + '\u0001' + (original || '');
        if (box.getAttribute('data-sig') === signature) { return; }
        box.setAttribute('data-sig', signature);
        while (box.firstChild) { box.removeChild(box.firstChild); }
        if (original) {
            // İngilizcesini de göster: özgün satır, çevirinin üstünde küçük harfle.
            var source = document.createElement('i');
            source.className = 'orig';
            source.textContent = original;
            box.appendChild(source);
        }
        if (speaker) {
            var who = document.createElement('b');
            who.textContent = speaker + ': ';
            who.setAttribute('data-name', speaker);
            box.appendChild(who);
        }
        box.appendChild(document.createTextNode(text));
        paint(box);
    }

    function removeRow(id) {
        var row = rows[id];
        delete rows[id];
        // Yalnız en üstteki satır yukarı kayarak çıkar. Aradan çıkan satır yukarı kayarsa
        // solarken üstündeki satırın yazısına biner; o yüzden yerinde solar.
        var above = row.previousSibling;
        while (above && /leaving/.test(above.className)) { above = above.previousSibling; }
        row.className = above ? 'row leaving inplace' : 'row leaving';
        setTimeout(function () {
            if (row.parentNode) { row.parentNode.removeChild(row); }
            applyStyle();
        }, 340);
    }

    function showLines(lines) {
        clearTimeout(safetyTimer);
        var keep = {};
        for (var i = 0; i < lines.length; i++) {
            var item = lines[i] || {};
            var text = String(item.t || '');
            if (!text) { continue; }
            var id = 'r' + (item.i !== undefined ? item.i : 'x' + i);
            keep[id] = true;
            var row = rows[id];
            if (!row) {
                row = document.createElement('div');
                row.className = 'row entering';
                row.appendChild(document.createElement('span'));
                subtitleEl.appendChild(row);
                rows[id] = row;
                recent.push({ s: item.s ? String(item.s) : '', t: text });
                if (recent.length > 6) { recent.shift(); }
                // Bir sonraki çizimde "entering" kalkar ve satır alttan kayarak belirir.
                (function (element) {
                    setTimeout(function () { if (element.className === 'row entering') { element.className = 'row'; } }, 30);
                })(row);
            }
            fillRow(row.firstChild, item.s ? String(item.s) : '', text, item.o ? String(item.o) : '');
        }
        for (var existing in rows) {
            if (rows.hasOwnProperty(existing) && !keep[existing]) { removeRow(existing); }
        }
        if (subtitleEl.firstChild) {
            safetyTimer = setTimeout(function () { showLines([]); }, SAFETY_CLEAR_MS);
        }
        applyStyle();
    }

    // ---------- Gizle / göster ----------

    /**
     * YEŞİL tuş (ya da telefondaki düğme): altyazıyı ve köşe yazılarını gizler; bir ara sahneyi yazısız
     * izlemek için. Çeviri arkada sürer, geri açınca kaldığı yerden görünür. Kalıcı değildir: uygulama
     * yeniden açılınca yazı yine görünür (gizli unutulup "bozuldu" sanılmasın).
     */
    var muted = false;

    function reportVisibility() {
        if (socket && socket.readyState === 1) {
            try { socket.send(JSON.stringify({ type: 'visibility', hidden: muted })); } catch (e) { /* bağlantı koptuysa yeniden bağlanınca bildirilir */ }
        }
    }

    function setMuted(on) {
        on = !!on;
        if (on !== muted) {
            muted = on;
            document.documentElement.className = muted ? 'muted' : '';
            showNotice(muted ? 'Altyazı gizlendi · YEŞİL tuşla geri gelir' : 'Altyazı açık', muted ? 3500 : 1500);
        }
        reportVisibility();
    }

    // ---------- Dublaj ----------

    /**
     * Telefon her repliğin Türkçe sesini üretip adresini yollar; televizyon sırayla çalar. Oyunun kendi sesi
     * sürer, Türkçe ses üstüne okunur. Konuşma hızlanınca geride kalmamak için sırada en çok iki replik bekler.
     */
    var phoneHost = null;
    var speechQueue = [];
    var speaking = null;

    function stopSpeech() {
        speechQueue = [];
        if (speaking) {
            try { speaking.pause(); } catch (e) { /* zaten durmuş */ }
            speaking = null;
        }
    }

    function reportSpoken(item, ok, startedAt) {
        if (socket && socket.readyState === 1) {
            try {
                socket.send(JSON.stringify({ type: 'spoke', path: item.path, ok: ok, wait: startedAt ? startedAt - item.at : -1 }));
            } catch (e) { /* bildirim yalnız ölçüm içindir */ }
        }
    }

    function speakNext() {
        if (speaking || !speechQueue.length) { return; }
        var item = speechQueue.shift();
        var audio = new Audio();
        var done = false;
        var startedAt = 0;
        var guard = null;
        function finish(ok) {
            if (done) { return; }
            done = true;
            clearTimeout(guard);
            if (speaking === audio) { speaking = null; }
            reportSpoken(item, ok, startedAt);
            speakNext();
        }
        speaking = audio;
        audio.volume = item.volume;
        audio.onplaying = function () { startedAt = Date.now(); };
        audio.onended = function () { finish(true); };
        audio.onerror = function () { finish(false); };
        // Ses hiç başlamazsa ya da bitişi bildirilmezse sıra tıkanmasın.
        guard = setTimeout(function () {
            try { audio.pause(); } catch (e) { /* zaten durmuş */ }
            finish(false);
        }, 25000);
        audio.src = (servedByPhone || !phoneHost ? '' : 'http://' + phoneHost + ':' + HTTP_PORT) + item.path;
        try {
            var playing = audio.play();
            if (playing && playing['catch']) { playing['catch'](function () { finish(false); }); }
        } catch (e) {
            finish(false);
        }
    }

    function onSpeak(message) {
        if (message.stop === true) { return stopSpeech(); }
        if (typeof message.path !== 'string' || message.path.indexOf('/ses/') !== 0) { return; }
        var volume = typeof message.volume === 'number' ? Math.max(0, Math.min(1, message.volume)) : 1;
        speechQueue.push({ path: message.path, volume: volume, at: Date.now() });
        while (speechQueue.length > 2) { reportSpoken(speechQueue.shift(), false, 0); }
        speakNext();
    }

    // ---------- "Takıldım" yardımcısı ----------

    var helpEl = document.getElementById('help');
    var helpTimer = null;
    var helpShowing = false;

    /** Telefondan istenen ipucu: ekranın sağında bir kutuda durur; süresi dolunca ya da GERİ tuşuyla kalkar. */
    function showHelp(message) {
        clearTimeout(helpTimer);
        while (helpEl.firstChild) { helpEl.removeChild(helpEl.firstChild); }
        helpShowing = message.state === 'working' || (message.state === 'done' && typeof message.text === 'string');
        if (!helpShowing) {
            helpEl.className = '';
            return;
        }
        var title = document.createElement('b');
        title.textContent = message.state === 'working' ? 'Yardımcı ekrana bakıyor…' : 'İpucu';
        helpEl.appendChild(title);
        if (message.state === 'done') {
            var body = document.createElement('div');
            body.textContent = message.text.slice(0, 900);
            helpEl.appendChild(body);
            helpTimer = setTimeout(function () { showHelp({}); }, Math.min(120000, Math.max(5000, message.ms || 45000)));
        } else {
            // Yanıt hiç gelmezse kutu ekranda takılı kalmasın.
            helpTimer = setTimeout(function () { showHelp({}); }, 100000);
        }
        helpEl.className = message.state === 'working' ? 'visible working' : 'visible';
    }

    // ---------- "Ekranı çevir" ----------

    function showNotice(text, forMs) {
        clearTimeout(noticeTimer);
        noticeEl.textContent = text || '';
        noticeEl.className = text ? 'visible' : '';
        if (text && forMs) { noticeTimer = setTimeout(function () { showNotice(''); }, forMs); }
    }

    function clearScreen() {
        while (screenEl.firstChild) { screenEl.removeChild(screenEl.firstChild); }
        screenShowing = false;
    }

    function showScreen(items) {
        clearScreen();
        if (secondScreen) { listItems(screenEl, items); } else { placeItems(screenEl, items, 0.82, 15); }
        screenShowing = items.length > 0;
    }

    /** Görev/ipucu yazıları: oyun sürerken köşede, özgün yazıların üstünde durur. */
    function showHud(items) {
        while (hudEl.firstChild) { hudEl.removeChild(hudEl.firstChild); }
        if (secondScreen) { return listItems(hudEl, items); }
        // Özgün yazıdan biraz küçük: çeviri yardımcıdır, oyunun kendi yazısını bastırmasın.
        placeItems(hudEl, items, 0.78, 17);
    }

    /**
     * İkinci ekranda (arkada oyun görüntüsü yokken) çeviriler oyundaki yerlerine konmaz; yukarıdan aşağıya,
     * soldan sağa okuma sırasıyla alt alta listelenir.
     */
    function listItems(layer, items) {
        var sorted = items.slice().sort(function (a, b) {
            return ((a.y || 0) - (b.y || 0)) || ((a.x || 0) - (b.x || 0));
        });
        for (var i = 0; i < sorted.length; i++) {
            var item = sorted[i] || {};
            if (!item.t) { continue; }
            var box = document.createElement('div');
            box.className = 'item listed';
            fillWithIcons(box, String(item.t), item.ic instanceof Array ? item.ic : []);
            layer.appendChild(box);
        }
    }

    /** Metni yazar; "[1]", "[2]"… işaretlerinin yerine oyundan kesilmiş tuş simgesinin resmini koyar. */
    function fillWithIcons(box, text, icons) {
        if (!icons.length) {
            box.textContent = text;
            return;
        }
        var pattern = /\[(\d+)\]/g;
        var last = 0;
        var match;
        while ((match = pattern.exec(text)) !== null) {
            var source = icons[parseInt(match[1], 10) - 1];
            if (typeof source !== 'string' || source.indexOf('data:image/') !== 0) { continue; }
            if (match.index > last) { box.appendChild(document.createTextNode(text.slice(last, match.index))); }
            var image = document.createElement('img');
            image.className = 'key';
            image.src = source;
            box.appendChild(image);
            last = match.index + match[0].length;
        }
        if (last < text.length) { box.appendChild(document.createTextNode(text.slice(last))); }
    }

    /** Çevirileri özgün yazıların üstüne, aynı boyda yerleştirir. Koordinatlar 0…1 (ekranın sol üstünden). */
    function placeItems(layer, items, sizeFactor, minimumSize) {
        var height = window.innerHeight;
        for (var i = 0; i < items.length; i++) {
            var item = items[i] || {};
            if (!item.t) { continue; }
            var box = document.createElement('div');
            var paragraph = item.n > 1;
            box.className = paragraph ? 'item block' : 'item';
            fillWithIcons(box, String(item.t), item.ic instanceof Array ? item.ic : []);
            // Özgün satır yüksekliğinden yazı boyutu; okunmayacak kadar küçük ya da dev olmasın.
            var size = Math.max(minimumSize, Math.min(64, (item.lh || 0.03) * height * sizeFactor));
            box.style.fontSize = size.toFixed(1) + 'px';
            box.style.left = ((item.x || 0) * 100).toFixed(2) + '%';
            box.style.top = ((item.y || 0) * 100).toFixed(2) + '%';
            if (paragraph) {
                // Türkçe çoğu zaman biraz daha uzun: paragrafa özgün genişliğinden biraz pay ver, ekrandan taşırma.
                var width = Math.min(1 - (item.x || 0) - 0.01, (item.w || 0.3) * 1.15);
                box.style.width = (width * 100).toFixed(2) + '%';
                box.style.minHeight = ((item.h || 0) * 100).toFixed(2) + '%';
            } else {
                box.style.minWidth = ((item.w || 0) * 100).toFixed(2) + '%';
                box.style.maxWidth = ((1 - (item.x || 0)) * 100).toFixed(2) + '%';
            }
            layer.appendChild(box);
        }
    }

    function onScreenMessage(message) {
        if (message.state === 'working') {
            clearScreen();
            screenShowing = true;   // GERİ tuşu çeviriyi iptal etsin
            showNotice('Ekran çevriliyor…');
        } else if (message.state === 'done') {
            showNotice('');
            showScreen(message.items instanceof Array ? message.items : []);
        } else if (message.state === 'error') {
            clearScreen();
            showNotice(String(message.message || 'Ekran çevrilemedi.'), 5000);
        } else {
            clearScreen();
            showNotice('');
        }
    }

    function requestScreen(type) {
        if (socket && socket.readyState === 1) {
            socket.send(JSON.stringify({ type: type }));
        } else {
            showNotice('Telefon bağlı değil.', 3000);
        }
    }

    function onMessage(raw) {
        var message;
        try { message = JSON.parse(raw); } catch (e) { return; }
        if (message.type === 'status') {
            heartbeat = true;
        } else if (message.type === 'screen') {
            onScreenMessage(message);
        } else if (message.type === 'speak') {
            onSpeak(message);
        } else if (message.type === 'help') {
            showHelp(message);
        } else if (message.type === 'mute') {
            setMuted(message.on === true);
        } else if (message.type === 'notice') {
            if (typeof message.text === 'string') { showNotice(message.text.slice(0, 200), Math.min(15000, Math.max(1000, message.ms || 5000))); }
        } else if (message.type === 'hud') {
            showHud(message.items instanceof Array ? message.items : []);
        } else if (message.type === 'lines') {
            showLines(message.lines instanceof Array ? message.lines : []);
        } else if (message.type === 'style') {
            if (message.position === 'top' || message.position === 'bottom') { style.position = message.position; }
            if (typeof message.scale === 'number' && message.scale > 0.3 && message.scale < 3) { style.scale = message.scale; }
            if (typeof message.color === 'string' && /^#[0-9a-fA-F]{6}$/.test(message.color)) { style.color = message.color; }
            if (typeof message.background === 'number' && message.background >= 0 && message.background <= 1) { style.background = message.background; }
            if (typeof message.bold === 'boolean') { style.bold = message.bold; }
            if (typeof message.speakerColors === 'boolean') { style.speakerColors = message.speakerColors; }
            store('position', style.position);
            store('scale', style.scale);
            store('color', style.color);
            store('background', style.background);
            store('bold', style.bold);
            store('speakerColors', style.speakerColors);
            applyStyle();
        }
    }

    // ---------- Telefonu bulma ----------

    /** Verilen adreste Marhilk telefonu var mı? Varsa açık soketi geri verir. */
    function probe(host, timeoutMs, done) {
        var finished = false;
        var ws;
        function finish(result) {
            if (finished) { return; }
            finished = true;
            clearTimeout(timer);
            if (!result && ws) {
                ws.onopen = ws.onmessage = ws.onerror = ws.onclose = null;
                try { ws.close(); } catch (e) { /* zaten kapalı */ }
            }
            done(result);
        }
        var timer = setTimeout(function () { finish(null); }, timeoutMs);
        try {
            ws = new WebSocket('ws://' + host + ':' + PORT);
        } catch (e) {
            finish(null);
            return;
        }
        ws.onmessage = function (event) {
            var hello;
            try { hello = JSON.parse(event.data); } catch (e) { hello = null; }
            // Aynı portu kullanan başka bir cihaza yanlışlıkla bağlanma.
            finish(hello && hello.type === 'hello' && hello.app === 'altyazitr' ? ws : null);
        };
        ws.onerror = function () { finish(null); };
        ws.onclose = function () { finish(null); };
    }

    var lastHeard = 0;          // telefondan son ileti
    var heartbeat = false;      // bu bağlantıda telefon düzenli durum iletisi yolluyor mu

    /** Bağlantı koptu: ekranı temizle; yoklama döngüsü telefonu yeniden bulur. */
    function dropped() {
        socket = null;
        showLines([]);
        showHud([]);
        clearScreen();
        showNotice('');
        showHelp({});
        stopSpeech();
        setStatus('Telefon bağlantısı koptu, yeniden deneniyor…', true);
        connect();
    }

    /**
     * Telefon Wi-Fi'dan düşerse ya da kapanırsa bağlantı "koptu" bildirimi hiç gelmeyebilir; TV bağlı
     * sanıp bekler. Telefon iki saniyede bir durum iletisi yollar: dokuz saniye ses çıkmazsa kopmuş sayılır.
     */
    function watchConnection() {
        setInterval(function () {
            if (socket && heartbeat && Date.now() - lastHeard > 9000) {
                var dead = socket;
                dead.onclose = dead.onmessage = dead.onerror = null;
                try { dead.close(); } catch (e) { /* zaten kapalı */ }
                dropped();
            }
        }, 3000);
    }

    function adopt(ws, host) {
        socket = ws;
        phoneHost = host;
        lastHeard = Date.now();
        heartbeat = false;
        try {
            ws.send(JSON.stringify({ type: 'hello', build: TV_BUILD, platform: onTV ? 'tizen' : (onWebOS ? 'webos' : 'browser') }));
        } catch (e) { /* bağlantı o an koptuysa yoklama yeniden kurar */ }
        showHud([]);   // önceki bağlantıdan kalan köşe yazısı ekranda takılı kalmasın
        if (muted) { reportVisibility(); }   // telefon yeniden açıldıysa yazının gizli olduğunu bilsin
        failuresOnSavedHost = 0;
        store('host', host);
        setStatus('Telefona bağlandı (' + host + ')');
        ws.onmessage = function (event) {
            lastHeard = Date.now();
            onMessage(event.data);
        };
        ws.onerror = null;
        ws.onclose = function () {
            if (socket === ws) { dropped(); }
        };
    }

    function ownAddress() {
        try {
            if (window.webapis && window.webapis.network) { return window.webapis.network.getIp(); }
        } catch (e) { /* aşağıda ele alınır */ }
        return null;
    }

    /**
     * Verilen adreste Marhilk telefonu var mı? Telefonun küçük web sunucusuna sorulur.
     *
     * Neden doğrudan bağlanmayı denemiyoruz: TV'nin tarayıcı motoru, art arda başarısız olan
     * WebSocket denemelerinden sonra YENİ denemeleri 1–5 saniye bekletir. Ağı WebSocket ile taramak
     * yüzlerce başarısız deneme demektir; ardından telefona yapılan asıl bağlantı da bekletilir ve
     * TV telefonu onlarca saniye "bulamaz". Sıradan web istekleri bu bekletmeye takılmaz.
     */
    function ask(host, timeoutMs, done) {
        var finished = false;
        var request = null;
        function finish(found) {
            if (finished) { return; }
            finished = true;
            clearTimeout(guard);
            done(found);
        }
        // Kesin süre sınırı: bazı istekler ne yanıt ne hata ne de zaman aşımı bildirir; tarama onları
        // beklerse sonsuza dek takılır (22 Kas 2026'da gerçek TV'de görüldü).
        var guard = setTimeout(function () {
            try { if (request) { request.abort(); } } catch (e) { /* zaten bitmiş */ }
            finish(false);
        }, timeoutMs + 400);
        try {
            request = new XMLHttpRequest();
            request.open('GET', 'http://' + host + ':' + HTTP_PORT + '/marhilk?' + Date.now(), true);
            request.timeout = timeoutMs;
            request.onload = function () { finish(request.status === 200 && String(request.responseText).indexOf('marhilk') === 0); };
            request.onerror = request.ontimeout = request.onabort = function () { finish(false); };
            request.send();
        } catch (e) {
            finish(false);
        }
    }

    /**
     * Telefonu bulma düzeni:
     *   1. Bilinen adres (telefonun son görüldüğü yer) iki saniyede bir, ayrı bir hattan yoklanır.
     *      Telefondaki uygulama ne zaman açılırsa açılsın bir-iki saniyede yakalanır.
     *   2. Bilinen adres yoksa ya da uzun süredir yanıt vermiyorsa (adres değişmiş olabilir) ağ taranır;
     *      tarama bilerek yavaştır (aynı anda az istek). Çok sayıda eşzamanlı istek TV'nin bağlantı
     *      havuzunu tıkıyor ve asıl isteğin de yanıt alamamasına yol açıyordu (22 Kas 2026'da ölçüldü).
     */
    var joining = false;        // telefona bağlanma sürüyor
    var knownMisses = 0;        // bilinen adresin art arda yanıt vermediği yoklama sayısı
    var sweeping = false;       // ağ taraması sürüyor
    var sweepRound = 0;

    function knownHost() {
        var query = /[?&]host=([^&]+)/.exec(window.location.search);
        if (query) { return { host: decodeURIComponent(query[1]), fixed: true }; }
        if (servedByPhone) { return { host: window.location.hostname, fixed: true }; }
        return { host: store('host'), fixed: false };
    }

    /** Telefonun olduğu bilinen adrese bağlanır. */
    function join(host) {
        if (socket || joining) { return; }
        joining = true;
        sweepRound++;            // süren tarama varsa bıraksın
        sweeping = false;
        setStatus('Telefona bağlanılıyor (' + host + ')…', true);
        // Süre uzun: tarayıcı bağlantıyı bekletiyor olabilir.
        probe(host, 9000, function (ws) {
            joining = false;
            if (ws) { adopt(ws, host); }
        });
    }

    /** Bilinen adresi yoklar; sonuç ne olursa olsun iki saniye sonra yeniden çalışır. */
    function pollKnown() {
        var known = knownHost();
        if (socket || joining || !known.host) {
            setTimeout(pollKnown, 2000);
            return;
        }
        ask(known.host, 1500, function (isPhone) {
            if (isPhone) {
                knownMisses = 0;
                join(known.host);
            } else {
                knownMisses++;
                if (known.fixed && knownMisses > 2) {
                    setStatus('Telefona ulaşılamıyor. Telefonda Marhilk açık olmalı.', true);
                }
            }
            setTimeout(pollKnown, 2000);
        });
    }

    /** Ağı yavaşça tarar (aynı anda en çok SCAN_BATCH istek). */
    function sweep() {
        var ip = ownAddress();
        var parts = ip ? ip.split('.') : [];
        if (parts.length !== 4) {
            setStatus('TV ağa bağlı değil. Telefonla aynı Wi-Fi ağına bağlayın.', true);
            return;
        }
        var prefix = parts.slice(0, 3).join('.') + '.';
        var next = 1;
        var mine = ++sweepRound;
        sweeping = true;
        setStatus('Telefon aranıyor… Telefonda Marhilk açık olmalı.', true);

        function runBatch() {
            if (mine !== sweepRound || socket || joining) { return; }
            if (next > 254) {
                sweeping = false;
                setStatus('Telefon bulunamadı. Telefonda Marhilk\'i açın; aynı Wi-Fi ağında olun.', true);
                return;
            }
            var waiting = 0;
            var end = Math.min(next + SCAN_BATCH - 1, 254);
            for (var n = next; n <= end; n++) {
                if (prefix + n === ip) { continue; }
                waiting++;
                (function (host) {
                    ask(host, SCAN_TIMEOUT_MS, function (isPhone) {
                        if (isPhone && mine === sweepRound) { join(host); }
                        waiting--;
                        if (waiting === 0) { setTimeout(runBatch, 150); }
                    });
                })(prefix + n);
            }
            next = end + 1;
            if (waiting === 0) { runBatch(); }
        }
        runBatch();
    }

    /** Tarama gerekiyor mu? Beş saniyede bir bakılır. */
    function sweepWhenNeeded() {
        var known = knownHost();
        // Adres kesin biliniyorsa (LG tarayıcısı, önizleme) tarama yapılmaz.
        var lost = !known.host || knownMisses >= 5;   // bilinen adres ~10 saniyedir yanıt vermiyor
        if (!socket && !joining && !sweeping && !known.fixed && lost) { sweep(); }
        setTimeout(sweepWhenNeeded, 5000);
    }

    function connect() {
        // Bağlantı koptuğunda çağrılır: yoklama ve tarama döngüleri zaten çalışıyor; yalnız sayaç sıfırlanır.
        knownMisses = 0;
    }

    // ---------- HDMI görüntüsü ----------

    /** LG (webOS): HDMI girişini sayfanın arkasına bir video öğesi olarak yerleştirir. */
    function showWebOSInput(number) {
        if (hdmiVideo && hdmiVideo.parentNode) { hdmiVideo.parentNode.removeChild(hdmiVideo); }
        hdmiVideo = document.createElement('video');
        hdmiVideo.id = 'hdmi';
        hdmiVideo.setAttribute('autoplay', 'autoplay');
        var source = document.createElement('source');
        source.setAttribute('type', 'service/webos-external');
        source.setAttribute('src', 'ext://hdmi:' + number);
        hdmiVideo.appendChild(source);
        document.body.insertBefore(hdmiVideo, document.body.firstChild);
        hdmiIndex = number - 1;
        store('hdmi', number);
        setStatus('Kaynak: HDMI ' + number);
    }

    function showVideo() {
        if (onWebOS) {
            document.body.className = 'webos';
            var remembered = parseInt(store('hdmi'), 10);
            showWebOSInput(remembered >= 1 && remembered <= 4 ? remembered : 1);
            return;
        }
        if (secondScreen) {
            document.body.className = 'second';
            return;
        }
        if (!onTV) {
            document.body.className = 'preview';
            // Önizlemede gerçek bir oyun karesi arka plan olarak verilebilir: ?bg=kare.png
            var background = /[?&]bg=([^&]+)/.exec(window.location.search);
            if (background) {
                document.body.style.background = '#000 url(' + decodeURIComponent(background[1]) + ') center / 100% 100% no-repeat';
            }
            return;
        }
        try {
            // 'BEHIND': görüntü sayfanın arkasında kalır, altyazı üstte görünür.
            window.tizen.tvwindow.show(function () {}, function (error) {
                setStatus('HDMI görüntüsü açılamadı: ' + (error && error.name), true);
            }, ['0px', '0px', '1920px', '1080px'], 'MAIN', 'BEHIND');

            window.tizen.systeminfo.getPropertyValue('VIDEOSOURCE', function (info) {
                var connected = info.connected || [];
                for (var i = 0; i < connected.length; i++) {
                    if (connected[i].type === 'HDMI') { hdmiSources.push(connected[i]); }
                }
                var wanted = parseInt(store('hdmi'), 10);
                if (!isNaN(wanted)) {
                    for (var j = 0; j < hdmiSources.length; j++) {
                        if (hdmiSources[j].number === wanted) { selectHdmi(j); }
                    }
                }
            }, function () { /* kaynak listesi alınamazsa TV'nin o anki kaynağı gösterilir */ });
        } catch (e) {
            setStatus('Bu TV HDMI görüntüsünü uygulama içinde gösteremiyor (' + e.name + ').', true);
        }
    }

    function selectHdmi(index) {
        if (!hdmiSources.length) {
            setStatus('Bağlı HDMI cihazı görünmüyor.');
            return;
        }
        hdmiIndex = (index + hdmiSources.length) % hdmiSources.length;
        var source = hdmiSources[hdmiIndex];
        window.tizen.tvwindow.setSource(source, function () {
            store('hdmi', source.number);
            setStatus('Kaynak: HDMI ' + source.number);
        }, function (error) {
            setStatus('HDMI ' + source.number + ' seçilemedi: ' + (error && error.name));
        });
    }

    // ---------- Kumanda ----------

    function setupRemote() {
        if (onTV) {
            try { window.tizen.tvinputdevice.registerKey('ColorF0Red'); } catch (e) { /* tuş yoksa HDMI değiştirme kapalı kalır */ }
            try { window.tizen.tvinputdevice.registerKey('ColorF3Blue'); } catch (e) { /* tuş yoksa ekran çevirisi telefondan başlatılır */ }
            try { window.tizen.tvinputdevice.registerKey('ColorF2Yellow'); } catch (e) { /* tuş yoksa geçmiş telefondan okunur */ }
            try { window.tizen.tvinputdevice.registerKey('ColorF1Green'); } catch (e) { /* tuş yoksa altyazı telefondan gizlenir */ }
            try {
                window.webapis.appcommon.setScreenSaver(window.webapis.appcommon.AppCommonScreenSaverState.SCREEN_SAVER_OFF);
            } catch (e) { /* ekran koruyucu ayarı desteklenmiyorsa önemli değil */ }
        }
        document.addEventListener('keydown', function (event) {
            switch (event.keyCode) {
            case 38: style.position = 'top'; break;       // ▲
            case 40: style.position = 'bottom'; break;    // ▼
            case 37: style.scale = Math.max(0.6, style.scale - 0.1); break;  // ◀
            case 39: style.scale = Math.min(1.8, style.scale + 0.1); break;  // ▶
            case 13:                                       // TAMAM
                if (onWebOS && !document.fullscreenElement && document.documentElement.requestFullscreen) {
                    // Tarayıcının adres çubuğu görüntüyü kırpmasın: ilk TAMAM tam ekrana geçirir.
                    try { document.documentElement.requestFullscreen(); } catch (e) { /* desteklenmiyorsa olduğu gibi kalır */ }
                }
                clearTimeout(panelTimer);
                panelEl.className = panelEl.className === 'hidden' ? '' : 'hidden';
                return;
            case 403:                                      // KIRMIZI
                if (onTV) { selectHdmi(hdmiIndex + 1); }
                if (onWebOS) { showWebOSInput((hdmiIndex + 1) % 4 + 1); }
                return;
            case 404:                                      // YEŞİL: altyazıyı gizle / göster
            case 71:                                       // (bilgisayar önizlemesinde "G" tuşu)
                setMuted(!muted);
                return;
            case 405:                                      // SARI: son replikleri yeniden göster
            case 89:                                       // (bilgisayar önizlemesinde "Y" tuşu)
                toggleRecall();
                return;
            case 406:                                      // MAVİ: ekrandaki her şeyi çevir / çeviriyi kaldır
            case 66:                                       // (bilgisayar önizlemesinde "B" tuşu)
                requestScreen('translateScreen');
                return;
            case 461:                                      // GERİ (LG)
            case 10009:                                    // GERİ (Samsung)
                if (helpShowing) {
                    // Önce ipucu kutusunu kaldır.
                    showHelp({});
                    return;
                }
                if (screenShowing) {
                    // Önce ekran çevirisini kaldır; uygulamadan çıkmak için bir kez daha basılır.
                    clearScreen();
                    showNotice('');
                    requestScreen('clearScreen');
                    return;
                }
                if (onTV) { window.tizen.application.getCurrentApplication().exit(); }
                return;
            default:
                return;
            }
            store('position', style.position);
            store('scale', style.scale);
            applyStyle();
        });
    }

    applyStyle();
    showVideo();
    setupRemote();
    pollKnown();
    sweepWhenNeeded();
    watchConnection();
})();

"""#

    static let styleCSS = #"""
html, body {
    margin: 0;
    width: 100%;
    height: 100%;
    overflow: hidden;
    /* Saydam olmalı: HDMI penceresi sayfanın arkasında gösterilir. */
    background: transparent;
    font-family: "SamsungOne", "Samsung Sharp Sans", Arial, sans-serif;
    color: #fff;
}

/* Yalnız bilgisayar tarayıcısındaki önizlemede: oyun görüntüsü yerine koyu zemin. */
body.preview {
    background: linear-gradient(160deg, #1d2a38, #0c1118);
}

/* İkinci ekran (tablet, bilgisayar, eski telefon): oyun görüntüsü yok; siyah zeminde büyük yazı. */
body.second { background: #000; }
body.second #subtitle { left: 4%; width: 92%; line-height: 1.3; }
/* Tarayıcının alt çubuğu yazının üstüne binmesin. */
body.second #subtitle.bottom { bottom: 10%; }
body.second #help { display: none; }
/* Görev yazıları, seçenekler ve "ekranı çevir"in sonucu: oyundaki yerlerinde değil, okunur bir liste hâlinde. */
body.second #hud, body.second #screen {
    left: 4%;
    top: 4%;
    width: 92%;
    height: auto;
}
body.second #screen { background: #000; -webkit-column-count: 2; column-count: 2; -webkit-column-gap: 4%; column-gap: 4%; }
body.second #hud .item.listed, body.second #screen .item.listed {
    position: static;
    display: block;
    margin: 0 0 0.45em;
    padding: 0;
    background: none;
    font-size: 2vw;
    line-height: 1.3;
    white-space: pre-line;
    -webkit-column-break-inside: avoid;
    break-inside: avoid;
}

/* LG (webOS) tarayıcısı: HDMI girişi tam ekran, her şeyin arkasında. */
body.webos { background: #000; }

#hdmi {
    position: absolute;
    left: 0;
    top: 0;
    width: 100%;
    height: 100%;
    z-index: -1;
    background: #000;
}

#subtitle {
    position: absolute;
    left: 12%;
    width: 76%;
    box-sizing: border-box;
    text-align: center;
    font-size: 1.35vw;
    font-weight: 500;
    line-height: 1.45;
    opacity: 0;
}

#subtitle.top { top: 5%; }
#subtitle.bottom { bottom: 3%; }
#subtitle.visible { opacity: 1; }

/* Konuşma dökümü: satırlar alt alta; yeni gelen alttan kayarak girer, çıkan yukarı doğru silinir. */
#subtitle .row {
    max-height: 6em;
    margin: 0.12em 0;
    opacity: 1;
    -webkit-transform: translateY(0);
    transform: translateY(0);
    -webkit-transition: opacity 0.22s linear, -webkit-transform 0.22s ease-out, max-height 0.3s ease-in, margin 0.3s ease-in;
    transition: opacity 0.22s linear, transform 0.22s ease-out, max-height 0.3s ease-in, margin 0.3s ease-in;
}

#subtitle .row.entering {
    opacity: 0;
    -webkit-transform: translateY(0.9em);
    transform: translateY(0.9em);
}

#subtitle .row.leaving {
    opacity: 0;
    max-height: 0;
    margin: 0;
    -webkit-transform: translateY(-0.7em);
    transform: translateY(-0.7em);
}

#subtitle span {
    display: inline;
    padding: 0.08em 0.4em;
    background: rgba(0, 0, 0, 0.62);
    border-radius: 0.18em;
    -webkit-box-decoration-break: clone;
    box-decoration-break: clone;
    text-shadow: 0 0 0.1em #000;
}

/* Aradan çıkan satır: kaymadan, yerinde solar (üstündeki satıra binmesin). */
#subtitle .row.leaving.inplace {
    -webkit-transform: translateY(0);
    transform: translateY(0);
}

/* Konuşanın adı */
#subtitle b {
    font-weight: 700;
    color: #ffd84d;
}

#panel {
    position: absolute;
    top: 3%;
    right: 2%;
    max-width: 44%;
    padding: 0.9vw 1.2vw;
    background: rgba(0, 0, 0, 0.78);
    border-radius: 0.6vw;
    font-size: 1.25vw;
    line-height: 1.5;
}

#panel.hidden { display: none; }
#status { font-weight: 600; }
#help { opacity: 0.75; font-size: 1.05vw; }

/* "Ekranı çevir" katmanı: her çeviri, özgün yazının üstünde durur ve onu kapatır. */
#screen, #hud {
    position: absolute;
    left: 0;
    top: 0;
    width: 100%;
    height: 100%;
    overflow: hidden;
    pointer-events: none;
}

#screen .item, #hud .item {
    position: absolute;
    box-sizing: border-box;
    padding: 0.08em 0.3em;
    background: rgba(6, 8, 12, 0.97);
    border-radius: 0.15em;
    color: #fff;
    font-weight: 500;
    line-height: 1.22;
    white-space: nowrap;
}

/* Paragraf: özgün metnin genişliğinde kalır, satır kırar. */
#screen .item.block, #hud .item.block { white-space: normal; }

/* Köşe yazılarının çevirisi: konuşma altyazısıyla aynı görünüm (yarı saydam zemin, okunaklı kalın yazı). */
#hud .item {
    padding: 0.22em 0.55em;
    background: rgba(0, 0, 0, 0.66);
    border-radius: 0.22em;
    font-weight: 500;
    line-height: 1.3;
    letter-spacing: 0.01em;
    text-shadow: 0 0 0.12em #000, 0 0.05em 0.1em rgba(0, 0, 0, 0.8);
    -webkit-font-smoothing: antialiased;
}

/* Bir kutunun birden çok parçası tek öğede, her parça kendi satırında gelir. */
#hud .item.block { white-space: pre-line; }

/* Çevirinin içindeki tuş simgesi (oyunun kendi simgesinden kesilir). */
.item img.key {
    height: 1.25em;
    width: auto;
    margin: 0 0.12em;
    vertical-align: -0.28em;
}

/* SARI tuş: son replikler, ekranın ortasında bir pano olarak. */
#recall {
    position: absolute;
    left: 20%;
    width: 60%;
    top: 28%;
    box-sizing: border-box;
    padding: 1vw 1.4vw;
    background: rgba(0, 0, 0, 0.82);
    border-radius: 0.8vw;
    font-size: 1.5vw;
    line-height: 1.45;
    display: none;
}

#recall.visible { display: block; }
#recall .line { margin: 0.35em 0; }
#recall b { font-weight: 700; color: #ffd84d; }

#notice {
    position: absolute;
    left: 50%;
    top: 46%;
    -webkit-transform: translate(-50%, -50%);
    transform: translate(-50%, -50%);
    padding: 0.7vw 1.4vw;
    background: rgba(0, 0, 0, 0.82);
    border-radius: 0.6vw;
    font-size: 1.5vw;
    display: none;
}

#notice.visible { display: block; }

/* "İngilizcesini de göster": özgün satır, çevirinin üstünde küçük ve soluk. */
#subtitle .orig {
    display: block;
    font-size: 0.66em;
    font-style: normal;
    font-weight: 400;
    line-height: 1.3;
    opacity: 0.78;
}

/* YEŞİL tuş: altyazı ve köşe yazıları gizli (çeviri arkada sürer). "Ekranı çevir" ve son replikler
   bilerek istenen şeylerdir; gizliyken de görünür. */
html.muted #subtitle,
html.muted #hud { visibility: hidden; }

/* "Takıldım" yardımcısı: ekranın sağında, oyunun ortasını kapatmayan ipucu kutusu. */
#help {
    position: absolute;
    right: 3vw;
    top: 16%;
    width: 27vw;
    padding: 1vw 1.2vw;
    background: rgba(0, 0, 0, 0.86);
    border-left: 0.35vw solid #ffd84d;
    border-radius: 0.5vw;
    font-size: 1.3vw;
    line-height: 1.4;
    white-space: pre-line;
    display: none;
}
#help.visible { display: block; }
#help b { display: block; margin-bottom: 0.4em; color: #ffd84d; font-size: 0.85em; letter-spacing: 0.04em; }
#help.working b { margin-bottom: 0; }
body.second #help { width: 44vw; font-size: 2.3vw; top: 6%; }

"""#

    static let configXML = #"""
<?xml version="1.0" encoding="UTF-8"?>
<widget xmlns="http://www.w3.org/ns/widgets" xmlns:tizen="http://tizen.org/ns/widgets" id="http://altyazitr.app/tv" version="0.1.0" viewmodes="maximized">
    <tizen:application id="AltyzTR001.AltyaziTR" package="AltyzTR001" required_version="2.4"/>
    <content src="index.html"/>
    <feature name="http://tizen.org/feature/screen.size.all"/>
    <icon src="icon.png"/>
    <name>Marhilk</name>
    <access origin="*" subdomains="true"/>
    <tizen:privilege name="http://tizen.org/privilege/tv.window"/>
    <tizen:privilege name="http://tizen.org/privilege/tv.inputdevice"/>
    <tizen:privilege name="http://tizen.org/privilege/internet"/>
    <tizen:privilege name="http://developer.samsung.com/privilege/network.public"/>
    <tizen:profile name="tv-samsung"/>
    <tizen:setting screen-orientation="landscape" context-menu="disable" background-support="disable" encryption="disable" install-location="auto" hwkey-event="enable"/>
</widget>

"""#

    /// Gömülü TV uygulamasının sürümü (dosyalarının özeti).
    static let build = "931db9a22d61"

    static let iconPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAIAAAB7GkOtAAAABGdBTUEAALGPC/xhBQAAACBjSFJNAAB6JgAAgIQAAPoAAACA6AAAdTAAAOpgAAA6mAAAF3CculE8AAAARGVYSWZNTQAqAAAACAABh2kABAAAAAEAAAAaAAAAAAADoAEAAwAAAAEAAQAAoAIABAAAAAEAAAIAoAMABAAAAAEAAAIAAAAAAAv4tYUAAAGfaVRYdFhNTDpjb20uYWRvYmUueG1wAAAAAAA8eDp4bXBtZXRhIHhtbG5zOng9ImFkb2JlOm5zOm1ldGEvIiB4OnhtcHRrPSJYTVAgQ29yZSA2LjAuMCI+CiAgIDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+CiAgICAgIDxyZGY6RGVzY3JpcHRpb24gcmRmOmFib3V0PSIiCiAgICAgICAgICAgIHhtbG5zOmV4aWY9Imh0dHA6Ly9ucy5hZG9iZS5jb20vZXhpZi8xLjAvIj4KICAgICAgICAgPGV4aWY6UGl4ZWxYRGltZW5zaW9uPjEwMjQ8L2V4aWY6UGl4ZWxYRGltZW5zaW9uPgogICAgICAgICA8ZXhpZjpQaXhlbFlEaW1lbnNpb24+MTAyNDwvZXhpZjpQaXhlbFlEaW1lbnNpb24+CiAgICAgIDwvcmRmOkRlc2NyaXB0aW9uPgogICA8L3JkZjpSREY+CjwveDp4bXBtZXRhPgpVgmNYAAAx8ElEQVR4Ae3dZ3AeSX7f8ScjEyQYQYIBzAtymXMCyWVc7pJ7OllS2VVn+U7lUunkUHohWSq/cNkuW+WSX5xPtnx1J/tUddbJLnHJTWAmwQTmnHPOmUjEE/0HeEuRPBJ4nnmme0J/YWuPAGa6pz/dMz88E3qCVRNXBPhCAAEEEDBPIGRek2kxAggggEC7AAHAOEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHAGEAAAQQMFSAADO14mo0AAggQAIwBBBBAwFABAsDQjqfZCCCAAAHA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aTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCBAADAGEEAAAUMFCABDO55mI4AAAgQAYwABBBAwVIAAMLTjaTYCCCDw/wECpOBaI+1z1wAAAABJRU5ErkJggg=="
}
