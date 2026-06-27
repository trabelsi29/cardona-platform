import { getAssetFromKV } from "@cloudflare/kv-asset-handler";
import manifestJSON from "__STATIC_CONTENT_MANIFEST";
const assetManifest = JSON.parse(manifestJSON);

export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      // Rediriger / vers cardona_app.html
      if (url.pathname === "/" || url.pathname === "") {
        url.pathname = "/cardona_app.html";
        return Response.redirect(url.toString(), 302);
      }
      return await getAssetFromKV(
        { request, waitUntil: ctx.waitUntil.bind(ctx) },
        { ASSET_NAMESPACE: env.__STATIC_CONTENT, ASSET_MANIFEST: assetManifest }
      );
    } catch (e) {
      return new Response("Page non trouvée", { status: 404 });
    }
  },
};
