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
    var TV_BUILD = 'gelistirme';
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
        lastHeard = Date.now();
        heartbeat = false;
        try {
            ws.send(JSON.stringify({ type: 'hello', build: TV_BUILD, platform: onTV ? 'tizen' : (onWebOS ? 'webos' : 'browser') }));
        } catch (e) { /* bağlantı o an koptuysa yoklama yeniden kurar */ }
        showHud([]);   // önceki bağlantıdan kalan köşe yazısı ekranda takılı kalmasın
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
