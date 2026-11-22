// icons.js — MD3 天气图标引擎（Material Symbols 版）
// 输出 <span class="material-symbols-outlined wx-icon-*">名称</span>

/* ----------------------------------------------------------------
   天气条件 → Material Symbols 图标名
   参考: https://fonts.google.com/icons?category=weather
   ---------------------------------------------------------------- */
const ICON_MAP = {
  100: 'wb_sunny',
  101: 'partly_cloudy_day',
  102: 'partly_cloudy_day',
  103: 'partly_cloudy_day',
  104: 'cloud',

  150: 'wb_sunny',
  151: 'partly_cloudy_night',
  152: 'partly_cloudy_night',
  153: 'partly_cloudy_night',

  300: 'thunderstorm',
  301: 'thunderstorm',
  302: 'thunderstorm',
  303: 'thunderstorm',
  304: 'thunderstorm',

  305: 'rainy',
  306: 'rainy',
  307: 'rainy',
  308: 'rainy',
  309: 'rainy',
  310: 'rainy',
  311: 'rainy',
  312: 'rainy',
  313: 'hail',
  314: 'rainy',
  315: 'rainy',
  316: 'rainy',
  317: 'rainy',
  318: 'rainy',
  350: 'rainy',
  351: 'rainy',
  399: 'rainy',

  400: 'grain',
  401: 'grain',
  402: 'grain',
  403: 'grain',
  404: 'grain',
  405: 'grain',
  406: 'grain',
  407: 'grain',
  408: 'grain',
  409: 'grain',
  410: 'grain',
  456: 'grain',
  457: 'grain',
  499: 'grain',

  500: 'foggy',
  501: 'foggy',
  502: 'grain',
  503: 'wind_power',
  504: 'wind_power',
  507: 'wind_power',
  508: 'wind_power',
  509: 'foggy',
  510: 'foggy',
  511: 'grain',
  512: 'grain',
  513: 'grain',
  514: 'foggy',
  515: 'foggy',

  900: 'wb_sunny',
  901: 'thermostat',

  1001: 'storm',
  1002: 'tornado',
  1004: 'grain',
  1005: 'thermostat',
  1006: 'wind_power',
  1007: 'wind_power',
  1009: 'wb_sunny',
  1010: 'wb_sunny',
  1014: 'thunderstorm',
  1015: 'hail',
  1016: 'thermostat',
  1017: 'foggy',
  1019: 'grain',
  1020: 'thunderstorm',
  1021: 'hail',
  1022: 'wb_sunny',
  1023: 'wind_power',
  1024: 'wb_sunny',
  1025: 'warning',
  1026: 'warning',
  1027: 'thermostat',
  1030: 'grain',
  1031: 'thunderstorm',
  1033: 'grain',
  1034: 'thermostat',
  1035: 'rainy',
  1037: 'warning',
  1038: 'rainy',
  1039: 'thermostat',
  1040: 'grain',
  1043: 'thunderstorm',
  1047: 'wind_power',
  1048: 'thermostat',
  1049: 'storm',
  1050: 'thermostat',
  1051: 'wind_power',
  1052: 'thunderstorm',
  1053: 'foggy',
  1055: 'storm',
  1056: 'thermostat',
  1057: 'hail',
  1058: 'thunderstorm',
  1059: 'thermostat',
  1060: 'foggy',
  1061: 'wind_power',
  1062: 'wind_power',
  1063: 'rainy',
  1064: 'rainy',
  1065: 'foggy',
  1066: 'wb_sunny',
  1067: 'grain',
  1076: 'rainy',
  1077: 'warning',
  1080: 'wind_power',
  1081: 'hail',
  1085: 'thunderstorm',
  1086: 'hail',
  1087: 'thermostat',
  1090: 'wb_sunny',
  9999: 'warning',
};

function getIconFromText(text) {
  if (!text) return 'cloud';
  const t = text.toLowerCase();

  if (t.includes('晴')) {
    if (t.includes('间') || t.includes('少云')) return 'partly_cloudy_day';
    return 'wb_sunny';
  }
  if (t.includes('多云')) {
    if (t.includes('夜间') || t.includes('night')) return 'partly_cloudy_night';
    return 'partly_cloudy_day';
  }
  if (t.includes('阴')) return 'cloud';
  if (t.includes('雷')) return 'thunderstorm';
  if (t.includes('毛毛雨')) return 'rainy';
  if (t.includes('暴雨')) return 'rainy';
  if (t.includes('雨')) {
    if (t.includes('夜间') || t.includes('night')) return 'rainy';
    return 'rainy';
  }
  if (t.includes('暴雪') || t.includes('大雪') || t.includes('中雪') || t.includes('雪')) {
    if (t.includes('夜间') || t.includes('night')) return 'grain';
    return 'grain';
  }
  if (t.includes('雨夹雪')) return 'grain';
  if (t.includes('雾')) return 'foggy';
  if (t.includes('霾')) return 'grain';
  if (t.includes('沙尘')) return 'wind_power';
  if (t.includes('台风') || t.includes('龙卷')) return 'storm';
  if (t.includes('冰雹')) return 'hail';
  if (t.includes('热')) return 'wb_sunny';
  if (t.includes('冷') || t.includes('寒')) return 'thermostat';
  if (t.includes('风')) return 'wind_power';
  if (t.includes('夜间')) return 'nightlight';
  return 'cloud';
}

function getAnimClass(iconName) {
  const map = {
    'wb_sunny':          'wx-icon-sun',
    'partly_cloudy_day': 'wx-icon-cloud-sun',
    'partly_cloudy_night':'wx-icon-cloud-moon',
    'cloud':             'wx-icon-cloud',
    'rainy':             'wx-icon-rain',
    'thunderstorm':      'wx-icon-lightning',
    'grain':             'wx-icon-snow',
    'foggy':             'wx-icon-fog',
    'wind_power':        'wx-icon-typhoon',
    'storm':             'wx-icon-typhoon',
    'hail':              'wx-icon-rain',
    'tornado':           'wx-icon-typhoon',
    'thermostat':        '',
    'nightlight':        'wx-icon-sun',
    'warning':           '',
  };
  return map[iconName] || '';
}

function iconHTML(iconName, size) {
  const animClass = getAnimClass(iconName);
  const styleAttr = size ? ` style="font-size:${size}px;width:${size}px;height:${size}px"` : '';
  return `<span class="material-symbols-outlined ${animClass}"${styleAttr} aria-hidden="true">${iconName}</span>`;
}

export const WeatherIcons = {
  getSVG(code) {
    const icon = ICON_MAP[String(code)] || 'cloud';
    return iconHTML(icon);
  },
  getSVGFromText(text) {
    if (!text) return iconHTML('cloud');
    if (/^\d+$/.test(String(text).trim())) {
      const code = Number(text);
      const icon = ICON_MAP[String(code)] || 'cloud';
      return iconHTML(icon);
    }
    const icon = getIconFromText(text);
    return iconHTML(icon);
  },
  getIconName(code) {
    return ICON_MAP[String(code)] || 'cloud';
  },
};

export { getIconFromText, getAnimClass, iconHTML };
