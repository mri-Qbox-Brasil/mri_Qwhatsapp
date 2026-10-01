local TABLES = {
    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_accounts` (
        `phone` VARCHAR(20) NOT NULL,
        `name` VARCHAR(40) NOT NULL,
        `about` VARCHAR(140) NOT NULL DEFAULT '',
        `avatar` VARCHAR(512) NULL,
        `last_seen` INT UNSIGNED NOT NULL DEFAULT 0,
        `privacy_last_seen` TINYINT(1) NOT NULL DEFAULT 1,
        `privacy_receipts` TINYINT(1) NOT NULL DEFAULT 1,
        `created_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`phone`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_chats` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `kind` VARCHAR(8) NOT NULL,
        `direct_key` VARCHAR(48) NULL,
        `name` VARCHAR(40) NULL,
        `avatar` VARCHAR(512) NULL,
        `description` VARCHAR(300) NULL,
        `only_admins` TINYINT(1) NOT NULL DEFAULT 0,
        `created_by` VARCHAR(20) NOT NULL,
        `created_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        UNIQUE KEY `direct_key` (`direct_key`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_members` (
        `chat_id` INT UNSIGNED NOT NULL,
        `phone` VARCHAR(20) NOT NULL,
        `role` VARCHAR(8) NOT NULL DEFAULT 'member',
        `joined_at` INT UNSIGNED NOT NULL,
        `last_read` INT UNSIGNED NOT NULL DEFAULT 0,
        `last_delivered` INT UNSIGNED NOT NULL DEFAULT 0,
        `cleared_before` INT UNSIGNED NOT NULL DEFAULT 0,
        `pinned` TINYINT(1) NOT NULL DEFAULT 0,
        `archived` TINYINT(1) NOT NULL DEFAULT 0,
        `muted` TINYINT(1) NOT NULL DEFAULT 0,
        PRIMARY KEY (`chat_id`, `phone`),
        KEY `phone` (`phone`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_messages` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `chat_id` INT UNSIGNED NOT NULL,
        `sender` VARCHAR(20) NOT NULL,
        `kind` VARCHAR(12) NOT NULL,
        `body` TEXT NULL,
        `media` VARCHAR(512) NULL,
        `meta` TEXT NULL,
        `reply_to` INT UNSIGNED NULL,
        `edited` TINYINT(1) NOT NULL DEFAULT 0,
        `revoked` TINYINT(1) NOT NULL DEFAULT 0,
        `created_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        KEY `chat` (`chat_id`, `id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_reactions` (
        `message_id` INT UNSIGNED NOT NULL,
        `phone` VARCHAR(20) NOT NULL,
        `emoji` VARCHAR(16) NOT NULL,
        PRIMARY KEY (`message_id`, `phone`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_hidden` (
        `message_id` INT UNSIGNED NOT NULL,
        `phone` VARCHAR(20) NOT NULL,
        PRIMARY KEY (`message_id`, `phone`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_starred` (
        `message_id` INT UNSIGNED NOT NULL,
        `phone` VARCHAR(20) NOT NULL,
        PRIMARY KEY (`message_id`, `phone`),
        KEY `phone` (`phone`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_blocks` (
        `phone` VARCHAR(20) NOT NULL,
        `blocked` VARCHAR(20) NOT NULL,
        PRIMARY KEY (`phone`, `blocked`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_statuses` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `phone` VARCHAR(20) NOT NULL,
        `kind` VARCHAR(8) NOT NULL,
        `body` VARCHAR(700) NULL,
        `media` VARCHAR(512) NULL,
        `color` VARCHAR(16) NULL,
        `created_at` INT UNSIGNED NOT NULL,
        `expires_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        KEY `phone` (`phone`),
        KEY `expires_at` (`expires_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_status_views` (
        `status_id` INT UNSIGNED NOT NULL,
        `phone` VARCHAR(20) NOT NULL,
        `viewed_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`status_id`, `phone`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],

    [[CREATE TABLE IF NOT EXISTS `mri_whatsapp_calls` (
        `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
        `caller` VARCHAR(20) NOT NULL,
        `callee` VARCHAR(20) NOT NULL,
        `video` TINYINT(1) NOT NULL DEFAULT 0,
        `caller_hidden` TINYINT(1) NOT NULL DEFAULT 0,
        `callee_hidden` TINYINT(1) NOT NULL DEFAULT 0,
        `created_at` INT UNSIGNED NOT NULL,
        PRIMARY KEY (`id`),
        KEY `caller` (`caller`),
        KEY `callee` (`callee`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
}

return function()
    for i = 1, #TABLES do
        MySQL.query.await(TABLES[i])
    end
end
