import http from 'node:http'

const BASE_PATH  = (process.env.VITE_BASE_PATH || '/').replace(/\/+$/, '')
const APP_PORT   = process.env.APP_PORT   || '3000'
const PROXY_PORT = process.env.PROXY_PORT || '8080'

/* ------------------------------------------------------------------ */
/*  Path helpers                                                       */
/* ------------------------------------------------------------------ */

/** Strip BASE_PATH prefix so the back-end sees a "bare" path. */
function stripBase(url) {
    if (BASE_PATH && (url === BASE_PATH || url.startsWith(BASE_PATH + '/'))) {
        return url.slice(BASE_PATH.length) || '/'
    }
    return url
}

/** Prepend BASE_PATH to an absolute path that doesn't already carry it. */
function addBase(p) {
    if (!BASE_PATH || !p) return p
    if (p === BASE_PATH || p.startsWith(BASE_PATH + '/')) return p
    if (p.startsWith('/')) return BASE_PATH + p
    return p
}

/* ------------------------------------------------------------------ */
/*  HTML rewriting                                                     */
/* ------------------------------------------------------------------ */

function rewriteHTML(html) {
    if (!BASE_PATH) return html

    let patchedNextData = false

    // 1. Patch __NEXT_DATA__ so the Next.js client-side router knows
    //    the basePath.  Next.js will then handle pushState/replaceState
    //    and data-fetching URLs on its own.
    html = html.replace(
        /(<script\s[^>]*id\s*=\s*["']__NEXT_DATA__["'][^>]*>)([\s\S]*?)(<\/script>)/i,
        (_match, open, json, close) => {
            try {
                const data = JSON.parse(json)
                data.basePath = BASE_PATH
                patchedNextData = true
                console.log('  ↳ patched __NEXT_DATA__.basePath')
                return open + JSON.stringify(data) + close
            } catch { return _match }
        },
    )

    // 2. Rewrite /_next/ asset paths everywhere (src, href, inline JSON).
    //    The reverse proxy only routes requests that carry the basePath
    //    prefix, so the browser MUST request assets through that prefix.
    html = html.replace(
        /(["'(])(\/\_next\/)/g,
        `$1${BASE_PATH}/_next/`,
    )

    // 3. Rewrite `src` attributes for non-_next assets (favicon, images …).
    //    Step 2 already handled /_next/ paths; the startsWith guard
    //    prevents double-rewriting those.
    html = html.replace(
        /(src\s*=\s*["'])(\/(?!\/)[^"']*)/gi,
        (_match, attr, path) => {
            if (path.startsWith(BASE_PATH)) return _match
            return attr + BASE_PATH + path
        },
    )

    // 4. Rewrite href on <link> elements (stylesheets, icons, preloads).
    //    We intentionally do NOT touch <a href> — Next.js handles
    //    navigation links via basePath to avoid double-prefixing.
    html = html.replace(
        /(<link\s[^>]*?href\s*=\s*["'])(\/(?!\/)[^"']*)/gi,
        (_match, before, path) => {
            if (path.startsWith(BASE_PATH)) return _match
            return before + BASE_PATH + path
        },
    )

    // 5. Rewrite url() in inline <style> blocks
    html = html.replace(
        /url\(\s*["']?(\/(?!\/)[^"')]+)/gi,
        (match, path) => {
            if (path.startsWith(BASE_PATH)) return match
            return match.replace(path, BASE_PATH + path)
        },
    )

    // 6. Remove integrity attrs — content changed so hashes won't match
    html = html.replace(/\s+integrity=["'][^"']*["']/gi, '')

    // 7. Fallback for App Router (no __NEXT_DATA__): inject a minimal
    //    pushState / replaceState / fetch shim.
    if (!patchedNextData) {
        console.log('  ↳ no __NEXT_DATA__ found, injecting routing shim')
        const shim = `<script data-base-proxy>
(function(){
  var B="${BASE_PATH}";
  function f(u){
    if(typeof u!=="string")return u;
    if(u.startsWith("/")&&u!==B&&!u.startsWith(B+"/"))return B+u;
    return u;
  }
  ["pushState","replaceState"].forEach(function(n){
    var o=history[n];history[n]=function(s,t,u){return o.call(this,s,t,f(u))};
  });
  var _f=window.fetch;
  window.fetch=function(u,o){return _f.call(this,typeof u==="string"?f(u):u,o)};
})();
</script>`
        html = html.replace(/<head([^>]*)>/i, `<head$1>${shim}`)
    }

    return html
}

/* ------------------------------------------------------------------ */
/*  HTTP proxy                                                         */
/* ------------------------------------------------------------------ */

const server = http.createServer((req, res) => {
    const stripped = stripBase(req.url)
    console.log(`${req.method} ${req.url} → ${stripped}`)

    const headers = { ...req.headers }
    // Ask back-end for uncompressed responses so we can rewrite HTML
    headers['accept-encoding'] = 'identity'

    const proxyReq = http.request(
        {
            hostname: '127.0.0.1',
            port: APP_PORT,
            path: stripped,
            method: req.method,
            headers,
        },
        (proxyRes) => {
            const h = { ...proxyRes.headers }

            // Rewrite redirect Location
            if (h.location) {
                const orig = h.location
                h.location = addBase(h.location)
                console.log(`  ↳ ${proxyRes.statusCode} Location: ${orig} → ${h.location}`)
            }

            // Rewrite Set-Cookie paths
            if (h['set-cookie']) {
                const cookies = Array.isArray(h['set-cookie'])
                    ? h['set-cookie']
                    : [h['set-cookie']]
                h['set-cookie'] = cookies.map((c) =>
                    c.replace(/path=\//i, `path=${BASE_PATH}/`),
                )
            }

            const isHTML = (h['content-type'] || '').includes('text/html')

            if (isHTML && BASE_PATH) {
                // Buffer the whole response so we can rewrite it
                const chunks = []
                proxyRes.on('data', (c) => chunks.push(c))
                proxyRes.on('end', () => {
                    let body = Buffer.concat(chunks).toString('utf8')
                    body = rewriteHTML(body)
                    const buf = Buffer.from(body, 'utf8')
                    h['content-length'] = String(buf.length)
                    delete h['transfer-encoding']
                    res.writeHead(proxyRes.statusCode, h)
                    res.end(buf)
                })
            } else {
                // Stream everything else straight through
                res.writeHead(proxyRes.statusCode, h)
                proxyRes.pipe(res)
            }
        },
    )

    proxyReq.on('error', (err) => {
        console.error(`Proxy error: ${err.message}`)
        res.writeHead(502)
        res.end('Bad Gateway')
    })

    req.pipe(proxyReq)
})

/* ------------------------------------------------------------------ */
/*  WebSocket upgrade                                                  */
/* ------------------------------------------------------------------ */

server.on('upgrade', (req, socket, head) => {
    const stripped = stripBase(req.url)

    const proxyReq = http.request({
        hostname: '127.0.0.1',
        port: APP_PORT,
        path: stripped,
        method: req.method,
        headers: req.headers,
    })

    proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
        socket.write(
            `HTTP/1.1 101 ${proxyRes.statusMessage}\r\n` +
                Object.entries(proxyRes.headers)
                    .map(([k, v]) => `${k}: ${v}`)
                    .join('\r\n') +
                '\r\n\r\n',
        )
        if (proxyHead.length) socket.write(proxyHead)
        proxySocket.pipe(socket)
        socket.pipe(proxySocket)
    })

    proxyReq.on('error', (err) => {
        console.error(`WebSocket proxy error: ${err.message}`)
        socket.end()
    })

    proxyReq.end()
})

/* ------------------------------------------------------------------ */
/*  Start                                                              */
/* ------------------------------------------------------------------ */

server.listen(PROXY_PORT, '0.0.0.0', () => {
    console.log(`==> Proxy listening on :${PROXY_PORT}`)
    console.log(`==> Stripping "${BASE_PATH}" → forwarding to 127.0.0.1:${APP_PORT}`)
})
