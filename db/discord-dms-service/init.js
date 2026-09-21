// Discord DMs Service - database bootstrap.
//
// MongoDB runs this once, from /docker-entrypoint-initdb.d/, when the data
// volume is created. It creates the indexes the service relies on and, only if
// the database is still empty, leaves a sample shift behind so a fresh stack
// has something to read.
//
// The indexes use the same keys, names and options as the service's own
// EnsureIndexes, so the service finds them already in place on boot.

const target = db.getSiblingDB(process.env.MONGO_INITDB_DATABASE || 'discord_dms');

target.channels.createIndex({ sessionId: 1, name: 1 }, { unique: true, name: 'session_channel_unique' });
target.members.createIndex({ sessionId: 1, playerId: 1 }, { unique: true, name: 'session_player_unique' });
target.messages.createIndex({ channelId: 1, createdAt: -1 }, { name: 'channel_created_at' });

if (target.channels.countDocuments() === 0) {
  const session = 'shift-demo';
  const minutesAgo = (minutes) => new Date(Date.now() - minutes * 60 * 1000);

  // The four channels every shift starts with.
  const channels = {};
  ['enrollment-check', 'faculty-check', 'course-registration', 'general-mod-chat'].forEach((name, index) => {
    channels[name] = new ObjectId();
    target.channels.insertOne({
      _id: channels[name],
      sessionId: session,
      name: name,
      createdAt: minutesAgo(30 - index),
    });
  });

  target.members.insertMany([
    // A moderator reaches every channel, so no channels are stored for them.
    { sessionId: session, playerId: 'player-moderator-1', role: 'moderator', channels: [], joinedAt: minutesAgo(29) },
    { sessionId: session, playerId: 'player-junior-1', role: 'junior',
      channels: ['enrollment-check', 'general-mod-chat'], joinedAt: minutesAgo(28) },
    { sessionId: session, playerId: 'player-junior-2', role: 'junior',
      channels: ['faculty-check', 'general-mod-chat'], joinedAt: minutesAgo(28) },
    // Moderation Service posts its verdicts into #general-mod-chat.
    { sessionId: session, playerId: 'moderation-service', role: 'moderator', channels: [], joinedAt: minutesAgo(27) },
  ]);

  target.messages.insertMany([
    { channelId: channels['enrollment-check'], senderId: 'player-junior-1',
      content: 'applicant-1000 is not on the enrollment list.', createdAt: minutesAgo(15) },
    { channelId: channels['faculty-check'], senderId: 'player-junior-2',
      content: 'applicant-1003 has a real card, but it expired last semester.', createdAt: minutesAgo(10) },
    { channelId: channels['general-mod-chat'], senderId: 'player-junior-1',
      content: 'The student ID of applicant-1000 does not match any issued card.', createdAt: minutesAgo(14) },
    { channelId: channels['general-mod-chat'], senderId: 'moderation-service',
      content: 'Applicant applicant-1000: accept was wrong, the evidence called for reject (-40).', createdAt: minutesAgo(12) },
    { channelId: channels['general-mod-chat'], senderId: 'moderation-service',
      content: 'Applicant applicant-1003: ban was wrong, the evidence called for flag (-20).', createdAt: minutesAgo(4) },
  ]);
}
