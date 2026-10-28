using System;
using System.IO;

namespace Ahna;

public sealed class Preferences
{
	private bool? recipientSavedNotifications;

	public string SavePath { get; set; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "아나");

	public bool Notifications { get; set; } = true;

	public bool RecipientSavedNotifications
	{
		get
		{
			return recipientSavedNotifications ?? Notifications;
		}
		set
		{
			recipientSavedNotifications = value;
		}
	}

	public bool RemoteEnabled { get; set; }

	public string RemoteUrl { get; set; } = "";

	public string RemoteKeyProtected { get; set; } = "";
}
