/* A tiny stand-in for the Vue 2 runtime, only for the project page demo. The real GL.iNet loads the TSEM view as a
 * runtime-only Vue 2 component (data, created, methods, render(h)). This mounts that SAME component object in a plain page:
 * h() builds nodes, a small patch keeps the DOM (and the cursor in inputs) stable, and assignments to data re-render. */
(function (g) {
	'use strict';
	var SVGNS = 'http://www.w3.org/2000/svg';

	function flat(a, out) {
		for (var i = 0; i < a.length; i++) {
			var c = a[i];
			if (Array.isArray(c)) flat(c, out);
			else if (c === null || c === undefined || c === false || c === true) continue;
			else if (typeof c === 'object') out.push(c);
			else out.push({ text: String(c) });
		}
		return out;
	}
	function h(tag, data, children) {
		if (Array.isArray(data) || typeof data === 'string' || typeof data === 'number') { children = data; data = {}; }
		return { tag: tag, data: data || {}, children: flat([].concat(children === undefined || children === null ? [] : children), []) };
	}
	function cls(c) {
		if (!c) return '';
		if (typeof c === 'string') return c;
		if (Array.isArray(c)) return c.map(cls).filter(Boolean).join(' ');
		return Object.keys(c).filter(function (k) { return c[k]; }).join(' ');
	}
	function applyData(el, oldD, newD) {
		oldD = oldD || {}; newD = newD || {};
		var k, oa = oldD.attrs || {}, na = newD.attrs || {};
		for (k in oa) if (!(k in na)) el.removeAttribute(k);
		for (k in na) {
			var v = na[k];
			if (v === null || v === undefined || v === false) el.removeAttribute(k);
			else if (el.getAttribute(k) !== (v === true ? '' : String(v))) el.setAttribute(k, v === true ? '' : String(v));
		}
		var nc = cls(newD['class']);
		if (nc) { if (el.getAttribute('class') !== nc) el.setAttribute('class', nc); } else if (oldD['class']) el.removeAttribute('class');
		var os = oldD.style, ns = newD.style;
		if (typeof ns === 'string') el.style.cssText = ns;
		else {
			if (os && typeof os === 'object') for (k in os) if (!ns || !(k in ns)) el.style[k] = '';
			if (ns) for (k in ns) el.style[k] = ns[k];
		}
		var oo = oldD.on || {}, no = newD.on || {}, store = el.__h || (el.__h = {});
		for (k in oo) if (!(k in no) && store[k]) { el.removeEventListener(k, store[k]); delete store[k]; }
		for (k in no) {
			if (store[k] !== no[k]) { if (store[k]) el.removeEventListener(k, store[k]); el.addEventListener(k, no[k]); store[k] = no[k]; }
		}
		var np = newD.domProps || {};
		for (k in np) if (el[k] !== np[k]) el[k] = np[k];
	}
	function create(v, ns) {
		if (v.text !== undefined) { v.el = document.createTextNode(v.text); return v.el; }
		var n = ns || (v.tag === 'svg' ? SVGNS : null);
		var el = n ? document.createElementNS(n, v.tag) : document.createElement(v.tag);
		applyData(el, null, v.data);
		for (var i = 0; i < v.children.length; i++) el.appendChild(create(v.children[i], n));
		v.el = el; v.ns = n;
		return el;
	}
	function patch(o, n) {
		if (o.text !== undefined && n.text !== undefined) {
			n.el = o.el; if (o.text !== n.text) o.el.nodeValue = n.text; return;
		}
		if (o.text !== undefined || n.text !== undefined || o.tag !== n.tag) {
			var rep = create(n, o.ns); o.el.parentNode.replaceChild(rep, o.el); return;
		}
		var el = n.el = o.el; n.ns = o.ns;
		applyData(el, o.data, n.data);
		var oc = o.children, nc = n.children, i, m = Math.min(oc.length, nc.length);
		for (i = 0; i < m; i++) patch(oc[i], nc[i]);
		for (i = m; i < nc.length; i++) el.appendChild(create(nc[i], n.ns));
		for (i = m; i < oc.length; i++) el.removeChild(oc[i].el);
	}
	function reactive(obj, notify) {
		var cache = new WeakMap();
		function wrap(o) {
			if (o === null || typeof o !== 'object') return o;
			if (cache.has(o)) return cache.get(o);
			var p = new Proxy(o, {
				get: function (t, k, r) { return wrap(Reflect.get(t, k, r)); },
				set: function (t, k, v) { var old = t[k]; t[k] = v; if (old !== v) notify(); return true; },
				deleteProperty: function (t, k) { delete t[k]; notify(); return true; }
			});
			cache.set(o, p);
			return p;
		}
		return wrap(obj);
	}
	function mount(comp, container) {
		var data = comp.data.call({}), vm, old = null, queued = false;
		function update() {
			queued = false;
			var nv = comp.render.call(vm, h);
			if (!old) container.appendChild(create(nv)); else patch(old, nv);
			old = nv;
		}
		function notify() { if (!queued) { queued = true; (g.requestAnimationFrame || setTimeout)(update); } }
		vm = reactive(data, notify);
		Object.keys(comp.methods || {}).forEach(function (k) { data[k] = comp.methods[k].bind(vm); });
		data.$forceUpdate = notify;
		if (comp.created) comp.created.call(vm);
		update();
		return { vm: vm, destroy: function () { if (comp.beforeDestroy) comp.beforeDestroy.call(vm); } };
	}
	g.MiniVue = { mount: mount, h: h };
})(typeof window !== 'undefined' ? window : this);
