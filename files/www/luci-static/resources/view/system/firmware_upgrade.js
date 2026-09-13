'use strict';
'require view';
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

return view.extend({
	title: _('固件在线更新'),

	render: function() {
		var statusText = E('span', { 'class': 'badge' }, ['未检查']);
		var actionContainer = E('div', { 'style': 'margin-top: 15px;' }, []);
		var currentTagTd = E('td', { 'class': 'td left' }, ['-']);
		var latestTagTd = E('td', { 'class': 'td left' }, ['-']);
		var publishDateTd = E('td', { 'class': 'td left' }, ['-']);
		var assetNameTd = E('td', { 'class': 'td left' }, ['-']);

		var logPre = E('pre', {
			'style': 'display: none; max-height: 350px; overflow-y: auto; background: #181818; color: #00ff66; padding: 12px; border-radius: 4px; font-family: monospace; font-size: 12px; margin-top: 15px;'
		}, ['等待执行...\n']);

		var checkBtn = E('button', {
			'class': 'btn cbi-button-action',
			'click': function(ev) {
				ev.preventDefault();
				checkBtn.disabled = true;
				checkBtn.textContent = '正在检查 GitHub 最新版本...';

				callGetFirmwareUpdateInfo().then(function(res) {
					checkBtn.disabled = false;
					checkBtn.textContent = '重新检查更新';

					if (!res || !res.latest_tag) {
						statusText.textContent = '检查失败，请检查网络连接';
						return;
					}

					currentTagTd.textContent = res.current_tag || '-';
					latestTagTd.innerHTML = '';
					latestTagTd.appendChild(externalLink(res.release_url, res.latest_tag));
					publishDateTd.textContent = res.published_at ? res.published_at.replace('T', ' ').replace('Z', ' UTC') : '-';
					assetNameTd.textContent = res.asset_name || '-';

					actionContainer.innerHTML = '';

					var upgradeBtn = E('button', {
						'class': 'btn cbi-button-' + (res.has_update ? 'positive' : 'neutral'),
						'click': function(ev2) {
							ev2.preventDefault();
							showUpgradeConfirmModal(res);
						}
					}, [res.has_update ? '立即一键无损升级' : '强制重新刷写当前最新版']);

					actionContainer.appendChild(upgradeBtn);

					if (res.has_update) {
						statusText.className = 'badge warning';
						statusText.textContent = '发现新版本固件';
					} else {
						statusText.className = 'badge success';
						statusText.textContent = '当前已是最新固件';
					}
				}).catch(function(err) {
					checkBtn.disabled = false;
					checkBtn.textContent = '检查更新';
					statusText.textContent = '请求出错: ' + (err.message || err);
				});
			}
		}, ['检查最新版本']);

		function showUpgradeConfirmModal(info) {
			ui.showModal('确认一键无损在线升级', [
				E('p', {}, [
					'系统将自动从 GitHub 下载最新版本固件（已预装 Open-Box、OpenClash、PassWall 等），',
					E('strong', {}, '并无损保留您现有的网络 IP、代理规则、Open-Box 数据库等所有配置！')
				]),
				E('p', { 'class': 'alert-message warning' }, [
					'⚠️ 升级刷写期间请保持电源稳定。写入完成后路由器将自动重启（约需 1~2 分钟）。'
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
							ui.hideModal();
							startUpgradeProcess(info);
						}
					}, ['确认开始升级'])
				])
			]);
		}

		function startUpgradeProcess(info) {
			checkBtn.disabled = true;
			actionContainer.style.display = 'none';
			logPre.style.display = 'block';
			logPre.textContent = '正在启动升级任务...\n';

			callStartFirmwareUpdate().then(function() {
				var pollTimer = window.setInterval(function() {
					callGetFirmwareUpdateLog().then(function(logData) {
						if (logData && logData.log) {
							logPre.textContent = logData.log;
							logPre.scrollTop = logPre.scrollHeight;
						}

						if (logData.status === 'rebooting') {
							window.clearInterval(pollTimer);
							ui.showModal('固件写入成功', [
								E('p', { 'class': 'alert-message success' }, ['✅ 固件已成功刷入磁盘！系统正在重启...']),
								E('p', { 'id': 'reboot-countdown' }, ['路由器正在重新启动，预计 60 秒后恢复访问...'])
							]);

							var countdown = 60;
							var cdTimer = window.setInterval(function() {
								countdown--;
								var el = document.getElementById('reboot-countdown');
								if (countdown <= 0) {
									window.clearInterval(cdTimer);
									window.location.reload();
								} else if (el) {
									el.textContent = '路由器正在重新启动，预计 ' + countdown + ' 秒后自动刷新页面...';
								}
							}, 1000);
						} else if (logData.status === 'failed') {
							window.clearInterval(pollTimer);
							ui.addNotification(null, E('p', {}, ['固件升级失败，请查看下方日志中的错误信息。']), 'error');
						}
					}).catch(function() {
						window.clearInterval(pollTimer);
						ui.showModal('正在重启', [
							E('p', { 'class': 'alert-message success' }, ['连接已断开，路由器正在重启，系统将在 60 秒后自动刷新...'])
						]);
						window.setTimeout(function() {
							window.location.reload();
						}, 60000);
					});
				}, 1500);
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, ['启动升级失败: ' + (e.message || e)]), 'error');
			});
		}

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [_('固件在线更新')]),
			E('div', { 'class': 'cbi-map-descr' }, [
				'从您的私有固件仓库（',
				externalLink(projectUrl, 'fu5502/immortalwrt-custom-firmware'),
				'）一键拉取最新 Release 镜像并执行无损保留配置刷入。固件已预装 Open-Box、OpenClash、PassWall，并预留 4096MB 根分区。'
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left', 'width': '25%' }, ['当前固件版本']),
						currentTagTd
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, ['最新发布版本']),
						latestTagTd
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, ['发布时间']),
						publishDateTd
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, ['固件资产文件']),
						assetNameTd
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td left' }, ['更新检查状态']),
						E('td', { 'class': 'td left' }, [
							statusText,
							' ',
							checkBtn
						])
					])
				]),
				actionContainer,
				logPre
			])
		]);
	}
});
