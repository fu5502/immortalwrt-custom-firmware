'use strict';
'require baseclass';
'require rpc';
'require ui';

var projectUrl = 'https://github.com/fu5502/immortalwrt-custom-firmware';

var callGetFirmwareUpdateInfo = rpc.declare({
	object: 'luci',
	method: 'getFirmwareUpdateInfo',
	expect: { result: {} }
});

var callStartFirmwareUpdate = rpc.declare({
	object: 'luci',
	method: 'startFirmwareUpdate',
	expect: { result: '' }
});

var callGetFirmwareUpdateLog = rpc.declare({
	object: 'luci',
	method: 'getFirmwareUpdateLog',
	expect: {}
});

function externalLink(url, label) {
	return E('a', {
		'href': url,
		'target': '_blank',
		'rel': 'noopener noreferrer'
	}, [label]);
}

return baseclass.extend({
	title: '自定义固件与在线更新',

	render: function() {
		var statusText = E('span', { 'class': 'badge' }, ['未检查']);
		var actionContainer = E('span', {}, []);
		var currentTagTd = E('td', { 'class': 'td left' }, ['-']);
		var latestTagTd = E('td', { 'class': 'td left' }, ['-']);

		var checkBtn = E('button', {
			'class': 'btn cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				checkBtn.disabled = true;
				checkBtn.textContent = '正在检查最新版本...';

				callGetFirmwareUpdateInfo().then(function(res) {
					checkBtn.disabled = false;
					checkBtn.textContent = '重新检查';

					if (!res || !res.latest_tag) {
						statusText.textContent = '检查失败，请检查网络';
						return;
					}

					currentTagTd.textContent = res.current_tag || '-';
					latestTagTd.innerHTML = '';
					latestTagTd.appendChild(externalLink(res.release_url, res.latest_tag));

					actionContainer.innerHTML = '';

					var upgradeBtn = E('button', {
						'class': 'btn cbi-button-' + (res.has_update ? 'positive' : 'neutral'),
						'style': 'margin-left: 8px;',
						'click': function(ev2) {
							ev2.preventDefault();
							showUpgradeConfirmModal(res);
						}
					}, [res.has_update ? '一键无损升级' : '重新刷写最新版']);

					actionContainer.appendChild(upgradeBtn);

					if (res.has_update) {
						statusText.className = 'badge warning';
						statusText.textContent = '发现新版本 (' + (res.published_at ? res.published_at.slice(0, 10) : '') + ')';
					} else {
						statusText.className = 'badge success';
						statusText.textContent = '已是最新固件';
					}
				}).catch(function(err) {
					checkBtn.disabled = false;
					checkBtn.textContent = '检查更新';
					statusText.textContent = '请求出错: ' + (err.message || err);
				});
			}
		}, ['检查更新']);

		function showUpgradeConfirmModal(info) {
			ui.showModal('确认固件无损在线升级', [
				E('p', {}, [
					'系统将自动从 GitHub 下载最新固件（含 Open-Box、OpenClash、PassWall 等），',
					E('strong', {}, '并 100% 保留您当前的网络 IP、代理节点与所有配置数据')
				]),
				E('p', { 'class': 'alert-message warning' }, [
					'⚠️ 升级过程中请勿断电或关机。刷写完成后路由器将自动重启（约需 1~2 分钟）。'
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.hideModal
					}, ['取消']),
					' ',
					E('button', {
						'class': 'btn cbi-button-positive',
						'click': function() {
							startUpgradeProcess(info);
						}
					}, ['确认开始升级'])
				])
			]);
		}

		function startUpgradeProcess(info) {
			var logPre = E('pre', {
				'style': 'max-height: 280px; overflow-y: auto; background: #181818; color: #00ff66; padding: 12px; border-radius: 4px; font-family: monospace; font-size: 12px;'
			}, ['正在启动升级任务...\n']);

			var tipP = E('p', { 'style': 'font-weight: bold;' }, ['⏳ 升级进行中，请勿刷新页面...']);

			ui.showModal('固件升级进度', [
				tipP,
				logPre
			]);

			callStartFirmwareUpdate().then(function() {
				var pollTimer = window.setInterval(function() {
					callGetFirmwareUpdateLog().then(function(logData) {
						if (logData && logData.log) {
							logPre.textContent = logData.log;
							logPre.scrollTop = logPre.scrollHeight;
						}

						if (logData.status === 'rebooting') {
							window.clearInterval(pollTimer);
							tipP.textContent = '✅ 固件已成功写入！路由器正在重启，系统将在 60 秒后自动刷新...';
							tipP.style.color = '#00aaff';
							var countdown = 60;
							var cdTimer = window.setInterval(function() {
								countdown--;
								if (countdown <= 0) {
									window.clearInterval(cdTimer);
									window.location.reload();
								} else {
									tipP.textContent = '✅ 固件已成功写入！路由器正在重启，' + countdown + ' 秒后自动刷新...';
								}
							}, 1000);
						} else if (logData.status === 'failed') {
							window.clearInterval(pollTimer);
							tipP.textContent = '❌ 升级失败，请查看上方日志原因。';
							tipP.style.color = 'red';
						}
					}).catch(function() {
						window.clearInterval(pollTimer);
						tipP.textContent = '✅ 连接已断开，路由器正在重启，60 秒后自动刷新...';
						window.setTimeout(function() {
							window.location.reload();
						}, 60000);
					});
				}, 1500);
			}).catch(function(e) {
				tipP.textContent = '启动失败: ' + (e.message || e);
			});
		}

		return E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['项目主页']),
				E('td', { 'class': 'td left' }, [
					externalLink(projectUrl, 'fu5502/immortalwrt-custom-firmware')
				])
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['当前固件版本']),
				currentTagTd
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['最新发布版本']),
				latestTagTd
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, ['在线固件更新']),
				E('td', { 'class': 'td left' }, [
					statusText,
					' ',
					checkBtn,
					actionContainer
				])
			])
		]);
	}
});
