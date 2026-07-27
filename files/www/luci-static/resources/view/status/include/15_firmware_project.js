'use strict';
'require baseclass';

var projectUrl = 'https://github.com/fu5502/immortalwrt-custom-firmware';

function externalLink(url, label) {
	return E('a', {
		'href': url,
		'target': '_blank',
		'rel': 'noopener noreferrer'
	}, [label]);
}

return baseclass.extend({
	title: '\u81ea\u5b9a\u4e49\u56fa\u4ef6',

	render: function() {
		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['\u9879\u76ee\u4e3b\u9875']),
				E('td', { 'class': 'td left' }, [
					externalLink(projectUrl, 'fu5502/immortalwrt-custom-firmware')
				])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['\u53d1\u5e03\u4e0b\u8f7d']),
				E('td', { 'class': 'td left' }, [
					externalLink(projectUrl + '/releases', 'GitHub Releases')
				])
			])
		]);
	}
});
