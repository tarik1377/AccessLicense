// Extended list of Reality targets for VLESS anti-detection
// These domains are chosen for:
// 1. High traffic volume (won't stand out among normal traffic)
// 2. TLS 1.3 + H2 support (matching modern browser fingerprints)
// 3. Geographic diversity (different CDN endpoints)
// 4. Long-lived TLS sessions (stable certificates)
const REALITY_TARGETS = [
    // Russian services (recommended for Russian clouds)
    { target: 'yandex.ru:443', sni: 'yandex.ru' },
    { target: 'ya.ru:443', sni: 'ya.ru' },
    { target: 'vk.com:443', sni: 'vk.com' },
    { target: 'sberbank.ru:443', sni: 'sberbank.ru' },
    { target: 'online.sberbank.ru:443', sni: 'online.sberbank.ru' },
    { target: 'mail.ru:443', sni: 'mail.ru' },
    { target: 'e.mail.ru:443', sni: 'e.mail.ru' },
    { target: 'storage.yandexcloud.net:443', sni: 'storage.yandexcloud.net' },
    { target: 'gosuslugi.ru:443', sni: 'gosuslugi.ru' },
    { target: 'esia.gosuslugi.ru:443', sni: 'esia.gosuslugi.ru' },
    { target: 'web.max.ru:443', sni: 'web.max.ru' },
    // Cloud & CDN providers (extremely high traffic, hard to block)
    { target: 'www.microsoft.com:443', sni: 'www.microsoft.com' },
    { target: 'www.google.com:443', sni: 'www.google.com' },
    { target: 'www.cloudflare.com:443', sni: 'www.cloudflare.com' },
    { target: 'one.one.one.one:443', sni: 'one.one.one.one' },
    { target: 'www.akamai.com:443', sni: 'www.akamai.com' },
    // Software & Development (common enterprise traffic)
    { target: 'github.com:443', sni: 'github.com' },
    { target: 'www.mozilla.org:443', sni: 'www.mozilla.org' },
    { target: 'www.docker.com:443', sni: 'www.docker.com' },
    { target: 'learn.microsoft.com:443', sni: 'learn.microsoft.com' },
    { target: 'code.visualstudio.com:443', sni: 'code.visualstudio.com' },
    // E-commerce & Business (very common traffic patterns)
    { target: 'www.samsung.com:443', sni: 'www.samsung.com' },
    { target: 'www.dell.com:443', sni: 'www.dell.com' },
    { target: 'www.hp.com:443', sni: 'www.hp.com' },
    { target: 'www.lenovo.com:443', sni: 'www.lenovo.com' },
    { target: 'www.asus.com:443', sni: 'www.asus.com' },
    // Media & Content (high bandwidth, long sessions)
    { target: 'www.spotify.com:443', sni: 'www.spotify.com' },
    { target: 'www.twitch.tv:443', sni: 'www.twitch.tv' },
    { target: 'www.pinterest.com:443', sni: 'www.pinterest.com' },
    { target: 'www.reddit.com:443', sni: 'www.reddit.com' },
    { target: 'stackoverflow.com:443', sni: 'stackoverflow.com' },
    // Enterprise & SaaS (typical corporate traffic)
    { target: 'www.oracle.com:443', sni: 'www.oracle.com' },
    { target: 'www.ibm.com:443', sni: 'www.ibm.com' },
    { target: 'www.cisco.com:443', sni: 'www.cisco.com' },
    { target: 'www.vmware.com:443', sni: 'www.vmware.com' },
    { target: 'www.salesforce.com:443', sni: 'www.salesforce.com' },
    // Regional diversity (for different ISP environments)
    { target: 'www.booking.com:443', sni: 'www.booking.com' },
    { target: 'www.airbnb.com:443', sni: 'www.airbnb.com' },
    { target: 'www.ebay.com:443', sni: 'www.ebay.com' },
    { target: 'www.paypal.com:443', sni: 'www.paypal.com' },
    { target: 'www.stripe.com:443', sni: 'www.stripe.com' },
];

/**
 * Returns a random Reality target configuration from the predefined list.
 * Uses crypto.getRandomValues for better randomness when available.
 * @returns {Object} Object with target and sni properties
 */
function getRandomRealityTarget() {
    let randomIndex;
    if (typeof crypto !== 'undefined' && crypto.getRandomValues) {
        const arr = new Uint32Array(1);
        crypto.getRandomValues(arr);
        randomIndex = arr[0] % REALITY_TARGETS.length;
    } else {
        randomIndex = Math.floor(Math.random() * REALITY_TARGETS.length);
    }
    const selected = REALITY_TARGETS[randomIndex];
    return {
        target: selected.target,
        sni: selected.sni
    };
}
