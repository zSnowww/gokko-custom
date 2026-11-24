.pragma library

function calcValue(expr) {
    var raw = String(expr || "").trim();
    if (raw === "") return null;
    // Percentages: "20% of 150", "150 + 20%", "150 - 15%"
    var pctOf = raw.match(/^(-?\d+(?:\.\d+)?)\s*%\s+(?:of|de)\s+(-?\d+(?:\.\d+)?)$/i);
    if (pctOf) return (Number(pctOf[1]) / 100) * Number(pctOf[2]);
    var pctRel = raw.match(/^(-?\d+(?:\.\d+)?)\s*([+-])\s*(\d+(?:\.\d+)?)\s*%$/);
    if (pctRel) {
        var base = Number(pctRel[1]), p = Number(pctRel[3]) / 100;
        return pctRel[2] === "+" ? base * (1 + p) : base * (1 - p);
    }
    var t = raw.replace(/[xX×]/g, "*").replace(/÷/g, "/").replace(/\^/g, "**");
    var stripped = t.replace(/\b(?:sqrt|abs|round|floor|ceil|sin|cos|tan|log|ln|pow|min|max|pi|e)\b/gi, "");
    if (!/^[0-9+\-*/%.,()\s*]+$/.test(stripped) || !/[0-9]/.test(t)) return null;
    var js = t
        .replace(/\bpi\b/gi, "Math.PI")
        .replace(/\be\b/gi, "Math.E")
        .replace(/\bsqrt\s*\(/gi, "Math.sqrt(")
        .replace(/\babs\s*\(/gi, "Math.abs(")
        .replace(/\bround\s*\(/gi, "Math.round(")
        .replace(/\bfloor\s*\(/gi, "Math.floor(")
        .replace(/\bceil\s*\(/gi, "Math.ceil(")
        .replace(/\bsin\s*\(/gi, "Math.sin(")
        .replace(/\bcos\s*\(/gi, "Math.cos(")
        .replace(/\btan\s*\(/gi, "Math.tan(")
        .replace(/\blog\s*\(/gi, "Math.log10(")
        .replace(/\bln\s*\(/gi, "Math.log(")
        .replace(/\bpow\s*\(/gi, "Math.pow(")
        .replace(/\bmin\s*\(/gi, "Math.min(")
        .replace(/\bmax\s*\(/gi, "Math.max(");
    try {
        var fn = new Function("\"use strict\"; return (" + js + ");");
        var v = fn();
        return (typeof v === "number" && isFinite(v)) ? v : null;
    } catch (err) {
        return null;
    }
}

function conversion(q) {
    var m = (q || "").trim().match(/^(-?\d+(?:\.\d+)?)\s*([a-z0-9°/]+)\s+(?:to|in|a|en)\s+([a-z0-9°/]+)$/i);
    if (!m) return null;
    var val = Number(m[1]), a = m[2].toLowerCase(), b = m[3].toLowerCase();
    var units = {
        mm:["len",0.001], cm:["len",0.01], m:["len",1], km:["len",1000], "in":["len",0.0254], ft:["len",0.3048], mi:["len",1609.344],
        mg:["mass",0.000001], g:["mass",0.001], kg:["mass",1], lb:["mass",0.45359237], oz:["mass",0.0283495],
        ml:["vol",0.001], l:["vol",1], gal:["vol",3.78541],
        ms:["time",0.001], s:["time",1], min:["time",60], h:["time",3600], d:["time",86400], day:["time",86400],
        b:["data",1], kb:["data",1000], mb:["data",1e6], gb:["data",1e9], tb:["data",1e12],
        kib:["data",1024], mib:["data",1048576], gib:["data",1073741824], tib:["data",1099511627776],
        "m/s":["spd",1], "km/h":["spd",1/3.6], kmh:["spd",1/3.6], mph:["spd",0.44704],
        deg:["ang",1], rad:["ang",180/Math.PI],
        c:["temp",1], "°c":["temp",1], f:["temp",1], "°f":["temp",1], k:["temp",1]
    };
    if (!units[a] || !units[b] || units[a][0] !== units[b][0]) return null;
    var result;
    if (units[a][0] === "temp") {
        var cel = (a === "f" || a === "°f") ? (val - 32) * 5 / 9 : (a === "k" ? val - 273.15 : val);
        result = (b === "f" || b === "°f") ? cel * 9 / 5 + 32 : (b === "k" ? cel + 273.15 : cel);
    } else {
        result = val * units[a][1] / units[b][1];
    }
    var resStr = String(Number(result.toPrecision(8)));
    return { valueStr: resStr, unit: b, formatted: resStr + " " + b, formula: q.trim() };
}
